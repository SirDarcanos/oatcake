import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct AskTests {
    /// Ask: the open meeting whole, then (only when the model says the question reaches beyond it)
    /// what a search of the others finds. The model's tags become links to the meetings and times.
    @Test func ask() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let sync = "Team/2026-11-09 1000 Weekly sync", earlier = "Team/2026-11-02 1000 Weekly sync", review = "Design/2026-11-06 1400 Design review"
        try meetings.write(sync, .transcript, "**[00:00] John Doe:** Morning.\n\n**[12:34] Jane Doe:** I will book the café for the offsite.\n",
                           meta: #"{"title":"Weekly sync","startedAt":"2026-11-09T10:00:00.000Z","participants":["John Doe","Jane Doe"]}"#)
        try meetings.write(sync, .todo, "- [x] Book the café — Jane Doe\n")
        var config = Config.defaults()
        config.outputDir = meetings.root.path

        // On its own: one request, and a bare time can only be in this meeting.
        let alone = try await StandIn.model { _ in "Jane Doe said she would book it [M1 12:34], which is done [M1]. See also [00:00]. A link: [x](https://example.com)." }
        config.llm = alone.config.llm
        let first = try await OatcakeCore.ask(config, meeting: sync, question: "Who is booking the café?")
        let here = "Team/2026-11-09%201000%20Weekly%20sync"
        #expect(first == "Jane Doe said they would book it [12:34](\(here)#12:34), which is done [Weekly sync · Nov 9](\(here)). See also [00:00](\(here)#00:00). A link: [x](https://example.com).")
        #expect(alone.requests.count == 1 && alone.requests[0].json["temperature"] as? Double == 0.6)
        let only = alone.requests[0].messages
        #expect(only.system.contains("[M1 12:34]") && only.user.hasPrefix("[M1] Weekly sync · Mon, Nov 9, 2026 (the meeting "))
        #expect(only.user.contains("To-dos ([x] = done):\n- [x] Book the café — Jane Doe") && only.user.contains("**[12:34] Jane Doe:** I will book the café"))
        #expect(only.user.hasSuffix("Question: Who is booking the café?"))

        // With other meetings: the model is asked first whether the question reaches them.
        try meetings.write(earlier, .summary, "## Offsite\n- The offsite is in March.\n", meta: #"{"title":"Weekly sync","startedAt":"2026-11-02T10:00:00.000Z"}"#)
        try meetings.write(earlier, .transcript, "**[03:10] Jane Doe:** The offsite budget is five thousand.\n\n**[04:00] John Doe:** Fine.\n")
        try meetings.write(review, .summary, "## Colours\n- New tokens agreed.\n", meta: #"{"title":"Design review","startedAt":"2026-11-06T14:00:00.000Z"}"#)
        let stays = try await StandIn.model { $0.json["response_format"] != nil ? #"{"beyond":false,"search":[]}"# : "Jane Doe [M1 12:34]." }
        config.llm = stays.config.llm
        config.llm.reasoning.ask = false
        _ = try await OatcakeCore.ask(config, meeting: sync, question: "Who is booking the café?")
        #expect(stays.requests.count == 2 && !stays.requests[1].messages.user.contains("[M2]"))
        #expect(stays.requests.map { $0.json["temperature"] as? Double } == [0.7, 0.7])

        let reaches = try await StandIn.model {
            $0.json["response_format"] != nil ? #"{"beyond":true,"search":["offsite budget","zebra"]}"#
                : "The budget is five thousand [M2 03:10], and Jane Doe is booking the café [M1, 12:34]. Nothing on colours [M3]. Not [M7]."
        }
        config.llm = reaches.config.llm
        let history = [AskExchange(question: "Who is booking the café?", answer: "Jane Doe [12:34](\(here)#12:34).")]
        let second = try await OatcakeCore.ask(config, meeting: sync, question: "What was the budget for the offsite?", history: history)
        let before = "Team/2026-11-02%201000%20Weekly%20sync"
        #expect(second == "The budget is five thousand [Weekly sync · Nov 2 · 03:10](\(before)#03:10), and Jane Doe is booking the café [12:34](\(here)#12:34). Nothing on colours [M3]. Not [M7].")
        let route = reaches.requests[0].messages.user, answer = reaches.requests[1].messages.user
        // Both begin with the open meeting, word for word: read once, kept for the answer and the next question.
        let open = try #require(route.range(of: "I will book the café for the offsite.")).upperBound
        #expect(answer.hasPrefix(route[..<open]) && route.hasSuffix("when \"beyond\" is false."))
        // The earlier meeting in the series was found by the search; the design review, which has neither phrase, wasn't.
        #expect(answer.contains("[M2] Weekly sync · Mon, Nov 2, 2026\n") && answer.contains("- The offsite is in March."))
        #expect(answer.contains("**[03:10] Jane Doe:** The offsite budget is five thousand.") && !answer.contains("**[04:00]") && !answer.contains("Design review"))
        #expect(answer.contains("Earlier in this conversation:\nQuestion: Who is booking the café?\nAnswer: Jane Doe 12:34."))
        #expect(answer.hasSuffix("Question: What was the budget for the offsite?"))
    }

    /// To-dos turned off: Ask isn't given them, in the open meeting or in the others it looks through.
    @Test func askWithoutTodos() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let sync = "Team/2026-11-09 1000 Weekly sync", review = "Design/2026-11-06 1400 Design review"
        try meetings.write(sync, .transcript, "**[12:34] Jane Doe:** I will book the café.\n", meta: #"{"title":"Weekly sync"}"#)
        try meetings.write(sync, .todo, "- [x] Book the café — Jane Doe\n")
        var config = Config.defaults()
        config.outputDir = meetings.root.path
        config.todosEnabled = false
        let server = try await StandIn.model { _ in "Jane Doe [M1 12:34]." }
        config.llm = server.config.llm
        _ = try await OatcakeCore.ask(config, meeting: sync, question: "Who is booking the café?")
        #expect(server.requests.count == 1)
        #expect(!server.requests[0].messages.user.contains("To-dos") && !server.requests[0].messages.user.contains("Book the café"))

        // Another meeting whose only mention of the deck is a to-do isn't found, and isn't given its to-dos.
        try meetings.write(review, .summary, "## Colours\n- New tokens agreed.\n", meta: #"{"title":"Design review"}"#)
        try meetings.write(review, .todo, "- [ ] Send the deck — Jane\n")
        let lib = Meetings(root: meetings.root)
        let others = lib.tree().allMeetings.filter { $0.path != sync }
        #expect(otherMeetings(lib, others: others, besides: sync, phrases: ["deck"], tokens: 2_000).map(\.path) == [review])
        #expect(otherMeetings(lib, others: others, besides: sync, phrases: ["deck"], tokens: 2_000, todos: false).isEmpty)
        let found = otherMeetings(lib, others: others, besides: sync, phrases: ["tokens"], tokens: 2_000, todos: false)
        #expect(found.map(\.path) == [review] && !found[0].text.contains("To-dos"))
    }

    @Test func askPieces() {
        // A tag with several times, a time past the hour, and a path that needs encoding.
        let odd = "Board (Q4)/2026-10-29 1630 Budget & plan #2"
        #expect(citationLinks("See [M1 1:02:03, 12:34].", sources: [odd]) == "See [1:02:03](Board%20%28Q4%29/2026-10-29%201630%20Budget%20%26%20plan%20%232#1:02:03), [12:34](Board%20%28Q4%29/2026-10-29%201630%20Budget%20%26%20plan%20%232#12:34).")
        // With more than one meeting in front of the model, a bare time is left alone: it could be in any of them.
        #expect(citationLinks("At [12:34].", sources: ["a/2026-10-29 1630 X", "b/2026-10-30 1630 Y"]) == "At [12:34].")
        #expect(citationLinks("Already [M1](x) a link.", sources: ["a/2026-10-29 1630 X"]) == "Already [M1](x) a link.")
        // A transcript that fits is given whole; one that doesn't, as the parts that share a word with the question.
        let turns = (0..<60).map { "**[\(clock(Double($0) * 60))] Jane:** " + ($0 == 40 ? "The zebra budget is nine thousand." : String(repeating: "filler ", count: 80).trimmed) }
        let whole = turns.joined(separator: "\n\n")
        #expect(transcriptFor(whole, question: "anything", tokens: 100_000) == (whole, true))
        let near = transcriptFor(whole, question: "What was the zebra budget?", tokens: 2_000)
        #expect(!near.whole && near.text == turns[39...41].joined(separator: "\n\n"))
        let start = transcriptFor(whole, question: "What happened?", tokens: 2_000)
        #expect(!start.whole && start.text.hasPrefix(turns[0]) && LocalModels.tokens(in: start.text) <= 2_000)
        #expect(questionWords("What did Joe Bloggs say about the Café budget?") == ["bloggs", "cafe", "budget"])
    }
}

import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct SummaryTests {
    /// A summary is two requests about the same transcript: the summary, following the instructions
    /// in Settings, then the to-dos as JSON. The second begins exactly as the first did, which is what
    /// lets the model answer it without reading the transcript again.
    @Test func summaryAndTodos() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] Sam Taylor:** Morning. Alex, where are we with the deck?\n\n**[00:04] Alex Kim:** I will send the deck on Friday.\n",
                           meta: #"{"title":"Weekly sync","startedAt":"2026-11-09T10:00:00.000Z","participants":["Sam Taylor","Alex Kim"]}"#)
        try meetings.write(rel, .notes, "- [00:03] Deck timing\n")
        let server = try await StandIn.model { request in
            request.json["response_format"] == nil
                ? "Here is the summary.\n\n## Deck\n- Alex Kim will send the deck on Friday.\n"
                : #"{"todos":[{"task":"send the deck","owner":"Alex Kim","due":"Friday","at":"[00:04]"},{"task":"Book a room","owner":"null","due":null,"at":null}]}"#
        }
        var config = server.config
        config.outputDir = meetings.root.path
        config.jargon = ["WooCommerce"]
        config.summaryInstructions = "Write three bullet points, in French."
        config.todoInstructions = "List only what Sam Taylor agreed to do."

        let draft = try await draftSummary(config, meeting: rel)
        #expect(draft.summary == "## Deck\n- Alex Kim will send the deck on Friday.\n")
        #expect(draft.todo == "- [ ] Send the deck — Alex Kim — due Friday — [00:04]\n- [ ] Book a room\n" && draft.todoProblem == nil)
        let sent = server.requests.map(\.messages)
        #expect(sent.count == 2 && sent[0].system == sent[1].system)
        #expect(sent[0].user.hasSuffix("Write three bullet points, in French.") && !sent[0].user.contains("Cover every topic"))
        #expect(sent[1].user.contains(#"{"todos": ["#) && server.requests[0].json["response_format"] == nil)
        #expect(sent[1].user.contains("\n\nList only what Sam Taylor agreed to do.\nFor each: task") && !sent[1].user.contains("small talk"))
        let shared = try #require(sent[0].user.range(of: "I will send the deck on Friday.\n\n")).upperBound
        #expect(sent[1].user.hasPrefix(sent[0].user[..<shared]))
        #expect(sent[0].user.hasPrefix("Meeting: Weekly sync\nParticipants: Sam Taylor, Alex Kim\n") && sent[0].user.contains("WooCommerce") && sent[0].user.contains("[00:03] Deck timing"))
        // The summary is reasoned over and the to-dos aren't, until Settings says otherwise: 0.6 is Qwen's sampling with reasoning, 0.7 without.
        #expect(server.requests.map { $0.json["temperature"] as? Double } == [0.6, 0.7])

        // Oatcake's own instructions when there are none of yours.
        config.summaryInstructions = ""
        config.todoInstructions = ""
        config.llm.reasoning.summary = false
        config.llm.reasoning.todos = true
        _ = try await draftSummary(config, meeting: rel)
        #expect(server.requests[2].messages.user.hasSuffix(defaultSummaryInstructions))
        #expect(server.requests[3].messages.user.hasSuffix(defaultTodoInstructions + "\n" + todosFormat))
        #expect(server.requests[2...].map { $0.json["temperature"] as? Double } == [0.7, 0.6])

        // A server that doesn't hold the model to the shape asked for: the summary is still written,
        // and the draft says the to-dos couldn't be read rather than passing for a call with none.
        let loose = try await StandIn.model { $0.json["response_format"] == nil ? "## Deck\n- Friday.\n" : "Sure! Alex will send the deck." }
        config.llm = loose.config.llm
        let unread = try await draftSummary(config, meeting: rel)
        #expect(unread == SummaryDraft(summary: "## Deck\n- Friday.\n", todo: "", todoProblem: todosUnreadMessage))
    }

    @Test func summaryPieces() {
        // Anything before the first heading goes, and a code fence around the lot.
        #expect(summaryBody("Sure!\n\n## Launch\n- Done.\n") == "## Launch\n- Done.")
        #expect(summaryBody("```markdown\n## Launch\n- Done.\n```") == "## Launch\n- Done.")
        #expect(summaryBody("Three points, as asked.") == "Three points, as asked.")
        // To-dos: what the model didn't know is left out, however it said so.
        let lines = todoLines(#"Here: {"todos":[{"task":"email Priya the figures","owner":"Sam","due":"none","at":"1:02:03"},{"task":"","owner":"Alex","due":null,"at":null},{"task":"Review — the plan","owner":"N/A","due":"Fri, Oct 30","at":"soon"}]}"#)
        #expect(lines == ["- [ ] Email Priya the figures — Sam — [1:02:03]", "- [ ] Review, the plan — due Fri, Oct 30"])
        // No to-dos is an answer; a reply that isn't the JSON asked for is no answer at all.
        #expect(todoLines(#"{"todos":[]}"#) == [] && todoLines("no JSON here") == nil)
        // A long call is cut between turns, and nothing is lost or repeated.
        let turns = (0..<40).map { "**[\(clock(Double($0) * 30))] Alex:** " + String(repeating: "word ", count: 60).trimmed }
        let whole = turns.joined(separator: "\n\n")
        let parts = splitTranscript(whole, tokens: 800)
        #expect(parts.count > 3 && parts.joined(separator: "\n\n") == whole)
        #expect(parts.allSatisfy { LocalModels.tokens(in: $0) <= 800 })
        #expect(splitTranscript(whole, tokens: 100_000) == [whole])
    }
}

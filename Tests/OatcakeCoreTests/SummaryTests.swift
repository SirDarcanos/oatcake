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
        try meetings.write(rel, .transcript, "**[00:00] John Doe:** Morning. Jane, where are we with the deck?\n\n**[00:04] Jane Doe:** I will send the deck on Friday.\n",
                           meta: #"{"title":"Weekly sync","startedAt":"2026-11-09T10:00:00.000Z","participants":["John Doe","Jane Doe"]}"#)
        try meetings.write(rel, .notes, "- [00:03] Deck timing\n")
        let server = try await StandIn.model { request in
            request.json["response_format"] == nil
                ? "Here is the summary.\n\n## Deck\n- Jane Doe will send the deck on Friday.\n"
                : #"{"todos":[{"task":"send the deck","owner":"Jane Doe","due":"Friday","at":"[00:04]"},{"task":"Book a room","owner":"null","due":null,"at":null}]}"#
        }
        var config = server.config
        config.outputDir = meetings.root.path
        config.jargon = ["WooCommerce"]
        config.summaryInstructions = "Write three bullet points, in French."
        config.todoInstructions = "List only what John Doe agreed to do."

        let draft = try await draftSummary(config, meeting: rel)
        #expect(draft.summary == "## Deck\n- Jane Doe will send the deck on Friday.\n")
        #expect(draft.todo == "- [ ] Send the deck — Jane Doe — due Friday — [00:04]\n- [ ] Book a room\n" && draft.todoProblem == nil)
        let sent = server.requests.map(\.messages)
        #expect(sent.count == 2 && sent[0].system == sent[1].system)
        #expect(sent[0].user.hasSuffix("Write three bullet points, in French.") && !sent[0].user.contains("Cover every topic"))
        #expect(sent[1].user.contains(#"{"todos": ["#) && server.requests[0].json["response_format"] == nil)
        #expect(sent[1].user.contains("\n\nList only what John Doe agreed to do.\nFor each: task") && !sent[1].user.contains("small talk"))
        let shared = try #require(sent[0].user.range(of: "I will send the deck on Friday.\n\n")).upperBound
        #expect(sent[1].user.hasPrefix(sent[0].user[..<shared]))
        #expect(sent[0].user.hasPrefix("Meeting: Weekly sync\nParticipants: John Doe, Jane Doe\n") && sent[0].user.contains("WooCommerce") && sent[0].user.contains("[00:03] Deck timing"))
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
        let loose = try await StandIn.model { $0.json["response_format"] == nil ? "## Deck\n- Friday.\n" : "Sure! Jane will send the deck." }
        config.llm = loose.config.llm
        let unread = try await draftSummary(config, meeting: rel)
        #expect(unread == SummaryDraft(summary: "## Deck\n- Friday.\n", todo: "", todoProblem: todosUnreadMessage))
    }

    /// Regenerate asks the model only for the part being written again, with the instructions in Settings now.
    @Test func regenerateAsksForOnePart() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] John:** We agreed to ship on Friday.\n")
        let server = try await StandIn.model { request in
            request.json["response_format"] == nil
                ? "## Replacement\nShip on Friday.\n"
                : #"{"todos":[{"task":"ship it","owner":"John","due":"Friday","at":"[00:00]"}]}"#
        }
        var config = server.config
        config.outputDir = meetings.root.path
        config.summaryInstructions = "Write in Italian."
        let summary = try await draftSummary(config, meeting: rel, only: .summary)
        #expect(server.requests.count == 1 && server.requests[0].json["response_format"] == nil)
        #expect(server.requests[0].messages.user.hasSuffix("Write in Italian."))
        #expect(summary.summary == "## Replacement\nShip on Friday.\n" && summary.todo.isEmpty && summary.todoProblem == nil)
        config.todoInstructions = "List only what John agreed to do."
        let todos = try await draftSummary(config, meeting: rel, only: .todos)
        #expect(server.requests.count == 2 && server.requests[1].json["response_format"] != nil)
        #expect(server.requests[1].messages.user.contains("List only what John agreed to do."))
        #expect(todos.todo == "- [ ] Ship it — John — due Friday — [00:00]\n")
    }

    /// A template picked for Regenerate summary is what the model is told, and the meeting keeps it
    /// once the summary is written: later summaries of it use it too. The default, a template that
    /// has gone, or one with no instructions, means the summary instructions.
    @Test func summaryTemplates() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 One-to-one"
        try meetings.write(rel, .transcript, "**[00:00] John:** We agreed to ship on Friday.\n",
                           meta: #"{"title":"One-to-one","recording":"2026-11-09T10-00-00-000Z"}"#)
        try meetings.write(rel, .summary, "## Old\n")
        let server = try await StandIn.model { _ in "## New\nShip on Friday.\n" }
        var config = server.config
        config.outputDir = meetings.root.path
        config.summaryInstructions = "Write in Italian."
        config.summaryTemplates = [SummaryTemplate(name: "1:1 I lead", instructions: "  List wins and blockers.\n"),
                                   SummaryTemplate(name: "Empty", instructions: " ")]
        let store = Meetings(root: meetings.root)
        let asked = { server.requests.last?.messages.user ?? "" }

        let draft = try await draftSummary(config, meeting: rel, only: .summary, template: .picked("1:1 I lead"))
        #expect(asked().hasSuffix("List wins and blockers.") && !asked().contains("Italian"))
        // Not kept until the summary is written, and not when it can't be (changed meanwhile).
        #expect(try store.read(rel).meta.template == nil)
        #expect(throws: (any Error).self) {
            try writeRegenerated(.summary, draft, config: config, meeting: rel, previous: "## Something else\n", template: .picked("1:1 I lead"))
        }
        #expect(try store.read(rel).meta.template == nil)
        try writeRegenerated(.summary, draft, config: config, meeting: rel, previous: "## Old\n", template: .picked("1:1 I lead"))
        var meta = try store.read(rel).meta
        #expect(meta.template == "1:1 I lead" && meta.recording == "2026-11-09T10-00-00-000Z" && meta.title == "One-to-one")

        // Written again later (Write summary, names put right): the meeting's own template.
        _ = try await draftSummary(config, meeting: rel)
        #expect(server.requests.dropLast().last?.messages.user.hasSuffix("List wins and blockers.") == true)
        // Regenerating to-dos leaves it alone.
        try writeRegenerated(.todos, SummaryDraft(summary: "", todo: ""), config: config, meeting: rel, previous: "", template: .picked(nil))
        #expect(try store.read(rel).meta.template == "1:1 I lead")

        // Back to the default.
        let plain = try await draftSummary(config, meeting: rel, only: .summary, template: .picked(nil))
        #expect(asked().hasSuffix("Write in Italian."))
        try writeRegenerated(.summary, plain, config: config, meeting: rel, previous: draft.summary, template: .picked(nil))
        meta = try store.read(rel).meta
        #expect(meta.template == nil && meta.recording == "2026-11-09T10-00-00-000Z")

        // A template that has gone since, or has no instructions: the summary instructions, and none is kept.
        try store.setSummaryTemplate(rel, "Deleted since")
        _ = try await draftSummary(config, meeting: rel, only: .summary)
        #expect(asked().hasSuffix("Write in Italian."))
        _ = try await draftSummary(config, meeting: rel, only: .summary, template: .picked("Empty"))
        #expect(asked().hasSuffix("Write in Italian."))
        try writeRegenerated(.summary, plain, config: config, meeting: rel, previous: plain.summary, template: .picked("Empty"))
        #expect(try store.read(rel).meta.template == nil)
    }

    /// A server of your own is sent as much of a call at once as its context holds, as you've set it:
    /// a long call that fits goes in one request, a smaller window splits it sooner, and with none set
    /// it's split as before. The prompt's own words and the room for the reply count against it too.
    @Test func ownServerContextDecidesParts() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "2026-11-09 1000 Planning"
        let line = "**[00:00] Jane Doe:** " + String(repeating: "We went through the plan for the quarter in detail. ", count: 12)
        let transcript = Array(repeating: line, count: 200).joined(separator: "\n\n") + "\n"
        try meetings.write(rel, .transcript, transcript, meta: #"{"title":"Planning","startedAt":"2026-11-09T10:00:00.000Z","participants":["Jane Doe"]}"#)
        let server = try await StandIn.model { $0.json["response_format"] == nil ? "## Plan\n- Agreed.\n" : #"{"todos":[]}"# }
        var config = server.config
        config.outputDir = meetings.root.path
        let size = LocalModels.tokens(in: transcript)
        #expect(size > 32_768 && size < 65_536)

        var parts: [Int] = []
        for context in [nil, 65_536, 16_384, size + 1_000, size + replyTokens + 3_000] {
            config.llm.own.context = context
            let before = server.requests.count
            _ = try await draftSummary(config, meeting: rel)
            let summaries = server.requests[before...].filter { $0.json["response_format"] == nil && $0.messages.user.contains("Transcript ([mm:ss]") }
            parts.append(summaries.count)
        }
        // None set: 32,768, so two parts. Room for the whole call: one. A small window: more parts.
        // Just bigger than the call, with no room for the instructions and the reply: still two.
        #expect(parts[0] == 2 && parts[1] == 1 && parts[2] > parts[0] && parts[3] == 2 && parts[4] == 1)
    }

    /// To-dos turned off: only the summary is asked for, and the meeting's todo.md is left as it was.
    @Test func noTodosWhenTurnedOff() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] John:** I will ship it on Friday.\n")
        try meetings.write(rel, .todo, "- [x] Saved before — John\n")
        let server = try await StandIn.model { request in
            request.json["response_format"] == nil
                ? "## Shipping\n- Friday.\n"
                : #"{"todos":[{"task":"ship it","owner":"John","due":"Friday","at":"[00:00]"}]}"#
        }
        var config = server.config
        config.outputDir = meetings.root.path
        config.todosEnabled = false
        try await writeSummary(config, meeting: rel)
        #expect(server.requests.count == 1 && server.requests[0].json["response_format"] == nil)
        let files = try Meetings(root: meetings.root).read(rel)
        #expect(files.summary == "## Shipping\n- Friday.\n" && files.todo == "- [x] Saved before — John\n")
        // Regenerate to-dos (hidden while they're off) still asks for them if it's asked.
        _ = try await draftSummary(config, meeting: rel, only: .todos)
        #expect(server.requests.count == 2 && server.requests[1].json["response_format"] != nil)
    }

    @Test func summaryPieces() {
        // Anything before the first heading goes, and a code fence around the lot.
        #expect(summaryBody("Sure!\n\n## Launch\n- Done.\n") == "## Launch\n- Done.")
        #expect(summaryBody("```markdown\n## Launch\n- Done.\n```") == "## Launch\n- Done.")
        #expect(summaryBody("Three points, as asked.") == "Three points, as asked.")
        // To-dos: what the model didn't know is left out, however it said so.
        let lines = todoLines(#"Here: {"todos":[{"task":"email Joe Bloggs the figures","owner":"John","due":"none","at":"1:02:03"},{"task":"","owner":"Jane","due":null,"at":null},{"task":"Review — the plan","owner":"N/A","due":"Fri, Oct 30","at":"soon"}]}"#)
        #expect(lines == ["- [ ] Email Joe Bloggs the figures — John — [1:02:03]", "- [ ] Review, the plan — due Fri, Oct 30"])
        // No to-dos is an answer; a reply that isn't the JSON asked for is no answer at all.
        #expect(todoLines(#"{"todos":[]}"#) == [] && todoLines("no JSON here") == nil)
        // A long call is cut between turns, and nothing is lost or repeated.
        let turns = (0..<40).map { "**[\(clock(Double($0) * 30))] Jane:** " + String(repeating: "word ", count: 60).trimmed }
        let whole = turns.joined(separator: "\n\n")
        let parts = splitTranscript(whole, tokens: 800)
        #expect(parts.count > 3 && parts.joined(separator: "\n\n") == whole)
        #expect(parts.allSatisfy { LocalModels.tokens(in: $0) <= 800 })
        #expect(splitTranscript(whole, tokens: 100_000) == [whole])
    }
}

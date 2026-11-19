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

    /// Regenerate asks the model only for the part being written again, with the instructions in Settings now.
    @Test func regenerateAsksForOnePart() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] Sam:** We agreed to ship on Friday.\n")
        let server = try await StandIn.model { request in
            request.json["response_format"] == nil
                ? "## Replacement\nShip on Friday.\n"
                : #"{"todos":[{"task":"ship it","owner":"Sam","due":"Friday","at":"[00:00]"}]}"#
        }
        var config = server.config
        config.outputDir = meetings.root.path
        config.summaryInstructions = "Write in Italian."
        let summary = try await draftSummary(config, meeting: rel, only: .summary)
        #expect(server.requests.count == 1 && server.requests[0].json["response_format"] == nil)
        #expect(server.requests[0].messages.user.hasSuffix("Write in Italian."))
        #expect(summary.summary == "## Replacement\nShip on Friday.\n" && summary.todo.isEmpty && summary.todoProblem == nil)
        config.todoInstructions = "List only what Sam agreed to do."
        let todos = try await draftSummary(config, meeting: rel, only: .todos)
        #expect(server.requests.count == 2 && server.requests[1].json["response_format"] != nil)
        #expect(server.requests[1].messages.user.contains("List only what Sam agreed to do."))
        #expect(todos.todo == "- [ ] Ship it — Sam — due Friday — [00:00]\n")
    }

    /// A template picked for Regenerate summary is what the model is told, and the meeting keeps it
    /// once the summary is written: later summaries of it use it too. The default, a template that
    /// has gone, or one with no instructions, means the summary instructions.
    @Test func summaryTemplates() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 One-to-one"
        try meetings.write(rel, .transcript, "**[00:00] Sam:** We agreed to ship on Friday.\n",
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

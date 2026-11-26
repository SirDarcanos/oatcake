import Foundation
@testable import OatcakeCore
import Testing

@Suite struct SharingTests {
    /// A draft for sharing is written from the summary and to-dos as they are, with the draft for
    /// sharing instructions and anything asked for this draft alone. The transcript and your notes
    /// aren't sent: a draft mustn't bring back what was taken out of the summary.
    @Test func draftFromSummaryAndTodos() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] John Doe:** The budget is off the record.\n",
                           meta: #"{"title":"Weekly sync","participants":["John Doe","Jane Doe"]}"#)
        try meetings.write(rel, .notes, "- [00:03] Private aside\n")
        try meetings.write(rel, .summary, "## Deck\n- Jane Doe will send the deck on Friday.\n")
        try meetings.write(rel, .todo, "- [ ] Send the deck — draft two — Jane Doe — due Friday — [00:04]\n- [x] Book a room — John Doe\n")
        let server = try await StandIn.model { _ in "```markdown\n## Decided\n- The deck goes out on Friday.\n```" }
        var config = server.config
        config.outputDir = meetings.root.path
        config.jargon = ["WooCommerce"]

        let draft = try await draftForSharing(config, meeting: rel, request: "  Keep it to three bullets.  ")
        #expect(draft == "## Decided\n- The deck goes out on Friday.\n")
        let sent = try #require(server.requests.first).messages
        #expect(sent.user.hasPrefix("Meeting: Weekly sync\nParticipants: John Doe, Jane Doe\n") && sent.user.contains("WooCommerce"))
        #expect(sent.user.contains("Summary:\n## Deck\n- Jane Doe will send the deck on Friday.\n"))
        // To-dos as people read them: no times in the call, and the done one says so.
        #expect(sent.user.contains("To-dos:\n- Send the deck — draft two — Jane Doe — due Friday\n- Book a room — John Doe — done\n"))
        #expect(sent.user.hasSuffix(defaultSharingInstructions + "\n\nFor this draft only: Keep it to three bullets."))
        #expect(!sent.user.contains("off the record") && !sent.user.contains("Private aside") && !sent.user.contains("[00:04]"))
        // A server of your own keeps its own sampling.
        #expect(server.requests[0].leavesSampling)
        // Nothing is written until the app puts it in place.
        #expect(try Meetings(root: meetings.root).read(rel).draft.isEmpty)

        // Your instructions, and no to-dos while they're turned off.
        config.sharingInstructions = "Write it in French."
        config.todosEnabled = false
        // Its own switch, not the summary's.
        config.llm.reasoning.sharing = false
        config.llm.reasoning.summary = true
        _ = try await draftForSharing(config, meeting: rel)
        let second = server.requests[1].messages.user
        #expect(second.hasSuffix("\n\nWrite it in French.") && !second.contains("To-dos:") && !second.contains("For this draft only"))
        #expect(server.requests[1].leavesSampling)
    }

    @Test func noSummaryNoDraft() async throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .transcript, "**[00:00] John Doe:** Hello.\n")
        let server = try await StandIn.model { _ in "## Draft\n" }
        var config = server.config
        config.outputDir = meetings.root.path
        await #expect(throws: OatcakeError("This meeting has no summary to draft from.")) {
            try await draftForSharing(config, meeting: rel)
        }
        #expect(server.requests.isEmpty)
    }

    /// The new draft takes the old one's place, unless the old one was edited while the model wrote.
    @Test func writeReplacesUnlessEdited() throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        try meetings.write(rel, .summary, "## Deck\n")
        var config = Config.defaults()
        config.outputDir = meetings.root.path

        try writeDraftForSharing("## First\n", config: config, meeting: rel, previous: "")
        #expect(try Meetings(root: meetings.root).read(rel).draft == "## First\n")
        try writeDraftForSharing("## Second\n", config: config, meeting: rel, previous: "## First\n")
        #expect(try Meetings(root: meetings.root).read(rel).draft == "## Second\n")
        #expect(throws: OatcakeError("The draft for sharing was changed while a new one was being written.")) {
            try writeDraftForSharing("## Third\n", config: config, meeting: rel, previous: "## First\n")
        }
        #expect(try Meetings(root: meetings.root).read(rel).draft == "## Second\n")
    }

    @Test func instructionsSetting() throws {
        let config = Config.defaults()
        #expect(config.sharingInstructions.isEmpty && config.sharingTask == defaultSharingInstructions)
        let saved = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.sharingInstructions = "Be brief." }).utf8))
        #expect(saved.sharingInstructions == "Be brief." && saved.sharingTask == "Be brief.")
        // Settings saved before the switch existed start it on; one turned off stays off.
        let older = try JSONDecoder().decode(LlmConfig.Reasoning.self, from: Data(#"{"summary":false}"#.utf8))
        #expect(older.sharing && !older.summary)
        let off = try JSONDecoder().decode(LlmConfig.Reasoning.self, from: Data(encodeJSON(with(LlmConfig.Reasoning()) { $0.sharing = false }).utf8))
        #expect(!off.sharing)
    }
}

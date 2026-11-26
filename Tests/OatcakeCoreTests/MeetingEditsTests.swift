import Foundation
@testable import OatcakeCore
import Testing

@Suite struct MeetingEditsTests {
    private func meeting() throws -> (root: URL, rel: String, dir: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-edits-\(UUID().uuidString)")
        let rel = "Team/2026-11-09 1000 Weekly sync"
        let dir = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        return (root, rel, dir)
    }

    /// Typing is written over the file only while the file is still what was read from it.
    @Test func writesOnlyOverWhatWasRead() throws {
        let (root, rel, dir) = try meeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = Meetings(root: root)
        let summary = dir.appendingPathComponent("summary.md")
        try "Jane will send the deck.\n".write(to: summary, atomically: true, encoding: .utf8)

        #expect(try meetings.write(rel, .summary, "Jane will send the deck on Friday.\n", ifUnchangedFrom: "Jane will send the deck.\n"))
        #expect(readText(summary) == "Jane will send the deck on Friday.\n")
        #expect(try !meetings.write(rel, .summary, "Something older\n", ifUnchangedFrom: "Jane will send the deck.\n"))
        #expect(readText(summary) == "Jane will send the deck on Friday.\n")
        // Nothing typed into a file that isn't there doesn't make an empty one.
        #expect(try meetings.write(rel, .notes, "", ifUnchangedFrom: ""))
        #expect(!FileManager.default.exists(dir.appendingPathComponent("notes.md")))
    }

    /// The summary arrives while a keystroke waits to be saved: the summary stays, and what was typed
    /// is kept beside it rather than written over it.
    @Test func summaryArrivingWhileTyping() throws {
        let (root, rel, dir) = try meeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = Meetings(root: root)
        let summary = dir.appendingPathComponent("summary.md")
        var edits = MeetingEdits()
        edits.typed("J", in: rel, .summary, before: "")
        edits.typed("Jo", in: rel, .summary, before: "J")
        #expect(edits.waiting.values.first?.loaded == "" && edits.texts(in: rel) == [.summary: "Jo"] && edits.isWaiting(in: rel))

        try "## Decisions\n\nJohn will book the room.\n".write(to: summary, atomically: true, encoding: .utf8)
        let key = MeetingEdits.Key(meeting: rel, file: .summary)
        #expect(edits.save(to: meetings) == [.setAside(key, "summary (your version).md")])
        #expect(readText(summary) == "## Decisions\n\nJohn will book the room.\n")
        #expect(readText(dir.appendingPathComponent("summary (your version).md")) == "Jo")
        #expect(edits.waiting.isEmpty)

        // Another one later goes beside both.
        edits.typed("Joe", in: rel, .summary, before: "")
        #expect(edits.save(to: meetings, in: rel) == [.setAside(key, "summary (your version 2).md")])
        #expect(readText(dir.appendingPathComponent("summary (your version 2).md")) == "Joe")
    }

    /// Edits are written and stop waiting; one that can't be written waits, marked as failed, until it
    /// can be. Saving one meeting leaves another's edits alone. A failure only counts while its
    /// meeting's folder is there.
    @Test func savingAndFailing() throws {
        let (root, rel, dir) = try meeting()
        let locked = root.appendingPathComponent("Read only/2026-11-11 1000 Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let meetings = Meetings(root: root)
        var edits = MeetingEdits()
        let gone = "Team/2026-11-10 1000 Gone"
        edits.typed("- [02:10] Ask about the budget\n", in: rel, .notes, before: "")
        edits.typed("Typed into a meeting that isn't there\n", in: gone, .notes, before: "")

        #expect(edits.save(to: meetings, in: rel).isEmpty)
        #expect(readText(dir.appendingPathComponent("notes.md")) == "- [02:10] Ask about the budget\n")
        #expect(edits.texts(in: gone) == [.notes: "Typed into a meeting that isn't there\n"])

        let outcomes = edits.save(to: meetings)
        guard case .failed(let key, _) = outcomes.first, outcomes.count == 1 else { Issue.record("Expected a failure: \(outcomes)"); return }
        // Its folder isn't there (deleted or moved in Finder, say): it waits, but isn't asked about.
        #expect(key == MeetingEdits.Key(meeting: gone, file: .notes) && edits.isWaiting(in: gone) && !edits.hasFailed(in: meetings))

        // One that can't be written into a folder that is there is.
        edits.typed("Jane will send the deck.\n", in: "Read only/2026-11-11 1000 Locked", .summary, before: "")
        #expect(edits.save(to: meetings).count == 2 && edits.hasFailed(in: meetings))

        // The meeting was renamed: its edit follows it, and can be written there.
        let renamed = "Team/2026-11-10 1000 Found"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(renamed), withIntermediateDirectories: true)
        edits.moved { $0 == gone ? renamed : $0 }
        #expect(edits.texts(in: renamed) == [.notes: "Typed into a meeting that isn't there\n"] && !edits.isWaiting(in: gone))
        #expect(edits.save(to: meetings, in: renamed).isEmpty && !edits.isWaiting(in: renamed))
        #expect(readText(root.appendingPathComponent(renamed + "/notes.md")) == "Typed into a meeting that isn't there\n")
    }

    /// A meeting, or a folder holding it, has gone to the Trash: what was waiting for it goes too, and
    /// nothing else does.
    @Test func trashedMeetingsLoseTheirEdits() {
        var edits = MeetingEdits()
        edits.typed("One\n", in: "Team/2026-11-09 1000 Weekly sync", .notes, before: "")
        edits.typed("Two\n", in: "Team/Leads/2026-11-10 1000 Leads sync", .summary, before: "")
        edits.typed("Three\n", in: "Teamwork/2026-11-11 1000 Retro", .notes, before: "")
        edits.typed("Four\n", in: "2026-11-12 1000 One-off", .notes, before: "")
        edits.discard(["Team", "2026-11-12 1000 One-off"])
        #expect(edits.waiting.keys.map(\.meeting) == ["Teamwork/2026-11-11 1000 Retro"])
    }

    /// To-dos ticked and added while the summary's to-dos are appended, from more than one `Meetings`
    /// at once, are all kept: no change lands between another's reading and writing the file.
    @Test func todoChangesDontOverlap() throws {
        let (root, rel, dir) = try meeting()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = dir.appendingPathComponent("todo.md")
        try "- [ ] Send the deck — Jane\n".write(to: file, atomically: true, encoding: .utf8)
        let mine = Meetings(root: root), summary = Meetings(root: root)
        let config = with(Config.defaults()) { $0.outputDir = root.path }
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            switch i % 3 {
            case 0: try? mine.addTodo(rel, "Added \(i)")
            case 1: try? writeSummary(SummaryDraft(summary: "Summary \(i)\n", todo: "- [ ] From the summary \(i)\n"), config: config, meeting: rel)
            default: _ = try? summary.toggleTodo(rel, line: 0, text: "Send the deck")
            }
        }
        let todos = parseTodos(readText(file))
        #expect(todos.count == 1 + 14 + 13)
        // Ticked 13 times: an odd number, so it ends up ticked.
        #expect(todos.first?.text == "Send the deck" && todos.first?.done == true)
    }
}

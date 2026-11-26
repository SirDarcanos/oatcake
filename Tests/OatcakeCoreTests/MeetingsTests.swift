import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct MeetingsTests {
    @Test func savedRecordingAudio() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-playback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Meetings")
        let rel = "Team/Weekly sync"
        let dir = root.appendingPathComponent(rel)
        let audio = dir.appendingPathComponent("audio.m4a")
        let outside = tmp.appendingPathComponent("audio.m4a")
        let meetings = Meetings(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: outside)

        #expect(meetings.recordingAudio(rel) == nil)
        try fm.createDirectory(at: audio, withIntermediateDirectories: false)
        #expect(meetings.recordingAudio(rel) == nil)
        try fm.removeItem(at: audio)
        try fm.createSymbolicLink(at: audio, withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Outside"), withDestinationURL: tmp)
        #expect(meetings.recordingAudio(rel) == nil)
        #expect(meetings.recordingAudio("Outside") == nil)
        #expect(meetings.recordingAudio("..") == nil)
        try fm.removeItem(at: audio)
        try Data().write(to: audio)
        #expect(meetings.recordingAudio(rel)?.path == audio.resolvingSymlinksInPath().path)
    }

    /// A folder in the Meetings folder that's a link to somewhere outside it isn't listed, read or
    /// written through, though what it leads to looks like a meeting. A link to a meeting inside the
    /// folder works as that meeting.
    @Test func linksOutOfTheFolderAreRefused() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-linked-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Meetings")
        let outside = tmp.appendingPathComponent("Elsewhere/2026-11-05 1400 Weekly sync")
        let inside = root.appendingPathComponent("Team/2026-11-06 1000 Planning")
        for dir in [outside, inside] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"title":"Weekly sync"}"#.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
            try "First line of prose.\n".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Linked meeting").path, withDestinationPath: "../Elsewhere/2026-11-05 1400 Weekly sync")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Linked folder").path, withDestinationPath: outside.deletingLastPathComponent().path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Planning").path, withDestinationPath: "Team/2026-11-06 1000 Planning")
        let meetings = Meetings(root: root)

        let tree = meetings.tree()
        #expect(tree.find("Linked meeting") == nil && tree.find("Linked folder") == nil)
        #expect(Set(tree.allMeetings.map(\.path)) == ["Planning", "Team/2026-11-06 1000 Planning"])
        for rel in ["Linked meeting", "Linked folder/2026-11-05 1400 Weekly sync"] {
            #expect(throws: OatcakeError.self) { try meetings.read(rel) }
            #expect(throws: OatcakeError.self) { try meetings.write(rel, .summary, "Written through the link.") }
            #expect(throws: OatcakeError.self) { try meetings.addTodo(rel, "Send the deck") }
        }
        #expect(throws: OatcakeError.self) { try meetings.createFolder(in: "Linked folder", named: "New") }
        #expect(meetings.search("prose", in: [("Linked meeting", "Weekly sync")]).isEmpty)
        #expect(readText(outside.appendingPathComponent("summary.md")) == "First line of prose.\n")
        #expect(try fm.contentsOfDirectory(atPath: outside.path).sorted() == ["meeting.json", "summary.md"])
        #expect(try fm.contentsOfDirectory(atPath: outside.deletingLastPathComponent().path) == ["2026-11-05 1400 Weekly sync"])

        // The link inside the folder is read and written as the meeting it leads to.
        #expect(tree.find("Planning")?.preview == "First line of prose.")
        #expect(try meetings.read("Planning").summary == "First line of prose.\n")
        try meetings.write("Planning", .notes, "Bring the figures.")
        #expect(readText(inside.appendingPathComponent("notes.md")) == "Bring the figures.")
    }

    @Test func folderNames() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 5, 14, 0)
        let date = gregorian.date(from: c)!
        #expect(meetingFolderName(title: "John / Jane: 1:1", startedAt: date) == "2026-11-05 1400 John - Jane- 1-1")
        #expect(meetingFolderName(title: "  ", startedAt: date) == "2026-11-05 1400 Call")
        #expect(loose("John & Jane 1:1") == loose("John & Jane 1-1"))
        #expect(safeName("A/B:  C") == "A-B- C")
        #expect(safeName(" ..Hidden") == "Hidden" && seriesFolder("...") == "Untitled")
    }

    /// An event whose title starts with a dot doesn't get a folder nobody can see.
    @Test func noHiddenFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-hidden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = Meetings(root: root)
        let folder = try meetings.folderForEvent(title: ".Standup", recurring: true)
        #expect(folder == "Standup" && meetings.tree().find(folder) != nil)
        #expect(throws: OatcakeError("Names can't start with a dot")) { try meetings.createFolder(in: "", named: ".hidden") }
        #expect(throws: OatcakeError("Names can't start with a dot")) { try meetings.rename(folder, to: "..") }
    }

    /// Ticking and adding to-dos works on the file as it is now, not as it was when the screen read it.
    @Test func todosFromTheFileAsItIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-todos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        let file = root.appendingPathComponent(rel + "/todo.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meetings = Meetings(root: root)
        // The screen read "One" and "Two"; the summary's to-do has been put above them since.
        try "- [ ] From the summary\n- [ ] One\n- [ ] Two\n".write(to: file, atomically: true, encoding: .utf8)
        try meetings.toggleTodo(rel, line: 1, text: "Two")
        #expect(readText(file) == "- [ ] From the summary\n- [ ] One\n- [x] Two\n")
        try meetings.toggleTodo(rel, line: 1, text: "One")
        try meetings.toggleTodo(rel, line: 0, text: "No longer there")
        try meetings.addTodo(rel, "Three — John")
        #expect(readText(file) == "- [ ] From the summary\n- [x] One\n- [x] Two\n- [ ] Three — John\n")
        // The Meetings folder's own list.
        try meetings.addTodo("", "Of my own")
        try meetings.toggleTodo("", line: 0, text: "Of my own")
        #expect(readText(root.appendingPathComponent("todo.md")) == "- [x] Of my own\n")
        // Your own list's to-dos can be put right, keeping their tick, or deleted; only todo.md is read for them.
        try meetings.addTodo("", "Renew the domian — John")
        #expect(try meetings.editTodo("", line: 1, text: "Renew the domian", to: typedTodo("Renew the domain - John - due Fri")))
        #expect(try meetings.editTodo("", line: 0, text: "Of my own", to: "Of my own, done — John"))
        #expect(try meetings.readTodo("") == "- [x] Of my own, done — John\n- [ ] Renew the domain — John — due Fri\n")
        #expect(try meetings.editTodo("", line: 0, text: "Of my own, done", to: nil))
        #expect(try !meetings.editTodo("", line: 0, text: "Gone since", to: nil))
        #expect(try meetings.readTodo("") == "- [ ] Renew the domain — John — due Fri\n" && meetings.readTodo("Team").isEmpty)
        // A file with a byte that isn't text (another editor's doing) still reads, so it isn't taken for empty and saved over.
        try Data([0x2D, 0x20, 0x5B, 0x20, 0x5D, 0x20, 0xFF, 0x4F, 0x6E, 0x65, 0x0A]).write(to: file)
        #expect(parseTodos(readText(file)).count == 1 && readText(file).contains("One"))
    }

    /// The To-dos page's lists are read from a tree that has just been read, without walking the folder again.
    @Test func todosFromATreeAlreadyRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-alltodos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func meeting(_ rel: String, todo: String?) throws {
            let dir = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
            try todo?.write(to: dir.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)
        }
        try meeting("Team/2026-11-09 1000 Weekly sync", todo: "- [ ] One\n")
        try meeting("2026-11-10 0900 One-off", todo: nil)
        try "- [ ] Mine\n".write(to: root.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)
        let meetings = Meetings(root: root)
        let tree = meetings.tree()
        // A meeting that arrives after the tree was read isn't in it, and isn't looked for.
        try meeting("2026-11-11 0900 Later", todo: "- [ ] Two\n")
        let fromTree = meetings.allTodos(in: tree)
        // Your own list first, then the meetings that have one.
        #expect(fromTree.map(\.path) == ["", "Team/2026-11-09 1000 Weekly sync"] && fromTree.map(\.todo) == ["- [ ] Mine\n", "- [ ] One\n"])
        #expect(Set(meetings.allTodos().map(\.path)) == ["", "Team/2026-11-09 1000 Weekly sync", "2026-11-11 0900 Later"])
    }

    @Test func fileOperations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = Meetings(root: root)
        let team = try meetings.createFolder(in: "", named: "Team 51")
        let leads = try meetings.createFolder(in: team, named: "Leads sync")
        let m = root.appendingPathComponent("\(leads)/2026-10-29 1630 Leads sync")
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try #"{"title":"Leads sync","startedAt":"2026-10-29T16:30:00.000Z"}"#.write(to: m.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        try "# Old\n- **Date:** x\n\nFirst line of prose.\n".write(to: m.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "- [ ] Do it — Jane\n".write(to: m.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)

        let tree = meetings.tree()
        #expect(tree.allMeetings.count == 1)
        #expect(tree.find("Team 51/Leads sync")?.meetings.first?.preview == "First line of prose.")
        #expect(matchingFolder("Team 51 – Leads sync", in: tree) == "Team 51/Leads sync")
        #expect(matchingFolder("leads SYNC!", in: tree) == "Team 51/Leads sync")
        #expect(throws: OatcakeError.self) { try resolveInside(root, "../escape") }
        #expect(throws: OatcakeError.self) { try meetings.createFolder(in: "", named: "a/b") }

        let moved = try meetings.move("Team 51/Leads sync", into: "")
        #expect(moved == "Leads sync")
        #expect(throws: OatcakeError.self) { try meetings.move("Team 51", into: "Team 51") }
        #expect(try meetings.rename("Team 51", to: "team 51") == "team 51")
        #expect(meetings.allTodos().map(\.path) == ["Leads sync/2026-10-29 1630 Leads sync"])
        #expect(try meetings.folderForEvent(title: "Leads sync", recurring: true) == "Leads sync")
        #expect(try meetings.folderForEvent(title: "Weekly: new", recurring: true) == "Weekly- new")
        #expect(try meetings.folderForEvent(title: "One-off", recurring: false) == "")

        // Renaming a meeting changes its title and its folder's name, and keeps meeting.json's other keys.
        let meeting = "Leads sync/2026-10-29 1630 Leads sync"
        try #"{"title":"Leads sync","startedAt":"2026-10-29T16:30:00.000Z","recording":"r1","granolaNote":"https://notes.granola.ai/d/x"}"#
            .write(to: root.appendingPathComponent(meeting + "/meeting.json"), atomically: true, encoding: .utf8)
        let renamed = try meetings.retitle(meeting, to: "Leads: Q4 plan")
        #expect(renamed == "Leads sync/2026-10-29 1630 Leads- Q4 plan")
        let node = try #require(meetings.tree().find(renamed))
        #expect(node.title == "Leads: Q4 plan" && node.startedAt != nil)
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(renamed + "/meeting.json"))) as? [String: String]
        #expect(kept?["recording"] == "r1" && kept?["granolaNote"] == "https://notes.granola.ai/d/x")
        #expect(throws: OatcakeError.self) { try meetings.retitle(renamed, to: "  ") }
    }

    @Test func eventsGoWhereTheirEarlierMeetingsAre() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-event-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func meeting(_ rel: String, _ title: String, _ started: String) throws {
            let dir = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"title":"\#(title)","startedAt":"\#(started)"}"#.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        }
        try meeting("Old/2026-10-05 1000 Weekly sync", "Weekly sync", "2026-10-05T10:00:00.000Z")
        try meeting("Team/2026-11-09 1000 Weekly sync", "Weekly Sync!", "2026-11-09T10:00:00.000Z")
        try meeting("2026-11-03 0900 Coffee", "Coffee", "2026-11-03T09:00:00.000Z")
        let meetings = Meetings(root: root)
        // No folder is called "Weekly sync", so it goes where the latest one is, recurring or not.
        #expect(try meetings.folderForEvent(title: "Weekly sync", recurring: true) == "Team")
        #expect(try meetings.folderForEvent(title: "weekly sync", recurring: false) == "Team")
        // The latest "Coffee" is at the top level, so no folder is made for it.
        #expect(try meetings.folderForEvent(title: "Coffee", recurring: true) == "")
        // A folder named like the event still comes first, and a new recurring event still gets its own.
        _ = try meetings.createFolder(in: "Team", named: "Weekly sync")
        #expect(try meetings.folderForEvent(title: "Weekly sync", recurring: false) == "Team/Weekly sync")
        #expect(try meetings.folderForEvent(title: "Board prep", recurring: true) == "Board prep")
        #expect(try meetings.folderForEvent(title: "One-off chat", recurring: false) == "")
    }

    @Test func searchesEveryMeetingsText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ file: MeetingFile, _ text: String) throws {
            let dir = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
            try text.write(to: dir.appendingPathComponent(file.rawValue), atomically: true, encoding: .utf8)
        }
        let sync = "Team/2026-11-09 1000 Weekly sync", review = "Design/2026-11-06 1400 Design review"
        try write(sync, .summary, "## Launch plan\n\nJane said the checklist is nearly done.\n")
        try write(sync, .transcript, "**[00:00] John:** Morning.\n\n**[12:34] Jane:** For the offsite in March I think that we could all meet up at the Café Lumière, if the budget allows.\n")
        try write(review, .notes, "- [02:10] Ask about the colour tokens\n")
        try write(review, .todo, "- [ ] Send the deck — Jane — [04:20]\n")
        let meetings = Meetings(root: root)
        let all = [(path: sync, label: "Weekly sync Team"), (path: review, label: "Design review Design")]

        // In a transcript, whatever the case or accents: the line, starting near the words, and its time.
        let cafe = meetings.search("cafe LUMIERE", in: all)
        #expect(cafe.map(\.path) == [sync])
        #expect(cafe.first?.file == .transcript && cafe.first?.stamp == "12:34")
        #expect(cafe.first?.line.hasPrefix("Jane: …") == true && cafe.first?.line.contains("meet up at the Café Lumière") == true)
        // A search for someone's name finds where they speak.
        #expect(meetings.search("john", in: all).first == SearchHit(path: sync, file: .transcript, line: "John: Morning.", stamp: "00:00"))
        // Notes and to-dos are looked through as well, and a line is shown as plain text.
        #expect(meetings.search("tokens", in: all).first?.file == .notes)
        #expect(meetings.search("deck", in: all).first == SearchHit(path: review, file: .todo, line: "Send the deck — Jane"))
        // Unless to-dos are turned off.
        #expect(meetings.search("deck", in: all, todos: false).isEmpty)
        #expect(meetings.search("tokens", in: all, todos: false).first?.file == .notes)
        // Words can be split between the title and the text, and every one of them is needed.
        #expect(meetings.search("weekly checklist", in: all).first == SearchHit(path: sync, file: .summary, line: "Jane said the checklist is nearly done."))
        #expect(meetings.search("weekly deck", in: all).isEmpty)
        // All in the title or folder: found, with no line to show.
        #expect(meetings.search("design review", in: all) == [SearchHit(path: review)])
        #expect(meetings.search("   ", in: all).isEmpty)
        // A file that changes is read again.
        try write(sync, .summary, "## Hiring\n\nThe zebra budget was agreed.\n")
        #expect(meetings.search("zebra", in: all).first?.line == "The zebra budget was agreed.")
        #expect(meetings.search("checklist", in: all).isEmpty)
        // A meeting that has moved is found where it is now.
        let moved = try meetings.move(sync, into: "Design")
        _ = meetings.tree()
        #expect(meetings.search("zebra", in: [(path: moved, label: "Weekly sync Design")]).map(\.path) == [moved])
        #expect(meetings.search("zebra", in: all).isEmpty)
    }

    /// A search whose task has been cancelled (the words changed while it ran) stops.
    @Test func cancelledSearchStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026-11-09 1000 Weekly sync")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        try "Jane said the checklist is nearly done.\n".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let meetings = Meetings(root: root)
        let all = [(path: "2026-11-09 1000 Weekly sync", label: "Weekly sync")]
        #expect(meetings.search("checklist", in: all).count == 1)
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return meetings.search("checklist", in: all)
        }
        #expect(await search.value.isEmpty)
    }

    /// The tree is read again from meeting.json when it changes, though what it says is kept between reads.
    @Test func treeFollowsMeetingJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        let file = root.appendingPathComponent(rel).appendingPathComponent("meeting.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"title":"Weekly sync","startedAt":"2026-11-09T10:00:00.000Z"}"#.write(to: file, atomically: true, encoding: .utf8)
        let meetings = Meetings(root: root)
        #expect(meetings.tree().find(rel)?.title == "Weekly sync")
        #expect(meetings.tree() == meetings.tree())

        try #"{"title":"Weekly sync with Jane","startedAt":"2026-11-10T10:00:00.000Z","source":"granola"}"#.write(to: file, atomically: true, encoding: .utf8)
        let node = try #require(meetings.tree().find(rel))
        #expect(node.title == "Weekly sync with Jane" && node.granola && node.startedAt == parseISO("2026-11-10T10:00:00.000Z"))
        // Edited by hand into something unreadable, it's still a meeting.
        try "{".write(to: file, atomically: true, encoding: .utf8)
        #expect(meetings.tree().find(rel)?.kind == .meeting && meetings.tree().find(rel)?.title == nil)
        // Without meeting.json, it's a folder.
        try FileManager.default.removeItem(at: file)
        #expect(meetings.tree().find(rel)?.kind == .folder)
    }
}

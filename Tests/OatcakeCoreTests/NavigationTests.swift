import Foundation
@testable import OatcakeCore
import Testing

@Suite struct NavigationTests {
    @Test func pathsFollowAMove() {
        #expect(remapped("Team", from: "Team", to: "Clients/Team") == "Clients/Team")
        #expect(remapped("Team/2026-11-05 1400 Weekly sync", from: "Team", to: "Clients/Team") == "Clients/Team/2026-11-05 1400 Weekly sync")
        // A sibling whose name only starts the same stays where it is.
        #expect(remapped("Team 51/Leads", from: "Team", to: "Clients/Team") == "Team 51/Leads")
        #expect(remapped("Other", from: "Team", to: "Clients/Team") == "Other")
        #expect(remapped("", from: "Team", to: "Clients/Team") == "")
    }

    @Test func aFolderThatHasGoneFallsBackToTheNearestThere() {
        let meeting = TreeNode(name: "2026-11-05 1400 Weekly sync", path: "Team/Leads/2026-11-05 1400 Weekly sync", kind: .meeting)
        let leads = TreeNode(name: "Leads", path: "Team/Leads", kind: .folder, children: [meeting])
        let team = TreeNode(name: "Team", path: "Team", kind: .folder, children: [leads])
        let tree = TreeNode(name: "Meetings", path: "", kind: .folder, children: [team])
        #expect(nearestFolder("Team/Leads", in: tree) == "Team/Leads")
        #expect(nearestFolder("Team/Leads/Old", in: tree) == "Team/Leads")
        #expect(nearestFolder("Team/Gone/Deeper", in: tree) == "Team")
        #expect(nearestFolder("Elsewhere", in: tree) == "")
        // A meeting isn't a folder to list.
        #expect(nearestFolder(meeting.path, in: tree) == "Team/Leads")
    }

    @Test func theNextRowAfterATrashIsMails() {
        let list = ["a", "b", "c", "d", "e"]
        #expect(rowAfterRemoving(["b"], from: list) == "c")
        #expect(rowAfterRemoving(["b", "c"], from: list) == "d")
        #expect(rowAfterRemoving(["b", "d"], from: list) == "e")
        // The last rows: the one before them.
        #expect(rowAfterRemoving(["e"], from: list) == "d")
        #expect(rowAfterRemoving(["d", "e"], from: list) == "c")
        #expect(rowAfterRemoving(Set(list), from: list) == nil)
        #expect(rowAfterRemoving(["x"], from: list) == nil)
    }

    @Test func backAndForward() {
        var history = History<String>()
        let all = { (_: String) in true }
        #expect(history.goBack(from: "home", where: all) == nil)
        history.leave("home")
        history.leave("a")
        #expect(history.canGoBack(from: "b", where: all))
        #expect(history.goBack(from: "b", where: all) == "a")
        #expect(history.goBack(from: "a", where: all) == "home")
        #expect(!history.canGoBack(from: "home", where: all))
        #expect(history.goForward(from: "home", where: all) == "a")
        #expect(history.goForward(from: "a", where: all) == "b")
        #expect(history.goForward(from: "b", where: all) == nil)
        // Following a link after going back drops what was ahead.
        _ = history.goBack(from: "b", where: all)
        history.leave("a")
        #expect(!history.canGoForward(from: "c", where: all))
    }

    @Test func backSkipsPlacesThatHaveGone() {
        var history = History<String>()
        history.leave("home")
        history.leave("trashed")
        let there = { (place: String) in place != "trashed" }
        #expect(history.goBack(from: "now", where: there) == "home")
        #expect(history.goForward(from: "home", where: there) == "now")
    }

    @Test func searchMatchesTitlesAsItMatchesText() {
        #expect(hasEveryWord(of: "cafe LUMIERE", in: "Café Lumière · Team › Leads"))
        #expect(hasEveryWord(of: "leads team", in: "Café Lumière · Team › Leads"))
        #expect(!hasEveryWord(of: "leads budget", in: "Café Lumière · Team › Leads"))
        #expect(hasEveryWord(of: "   ", in: "Anything"))
    }

    @Test func aMeetingMovedToTheTrashCanBePutBack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-putback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Meetings")
        let rel = "Team/2026-11-05 1400 Weekly sync"
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
        try "Jane Doe said hello.".write(to: root.appendingPathComponent(rel + "/summary.md"), atomically: true, encoding: .utf8)
        // Stands in for the Trash: the tests leave your own alone.
        let trash = tmp.appendingPathComponent("Trash/Weekly sync")
        try fm.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: root.appendingPathComponent(rel), to: trash)
        let meetings = Meetings(root: root)

        try meetings.putBack(trash, to: rel)
        #expect(readText(root.appendingPathComponent(rel + "/summary.md")) == "Jane Doe said hello.")
        #expect(!fm.exists(trash))

        // Something else in its place: it stays in the Trash.
        try fm.moveItem(at: root.appendingPathComponent(rel), to: trash)
        try fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
        #expect(throws: OatcakeError.self) { try meetings.putBack(trash, to: rel) }
        #expect(fm.exists(trash))

        // The folder it was in has gone.
        try fm.removeItem(at: root.appendingPathComponent("Team"))
        #expect(throws: OatcakeError.self) { try meetings.putBack(trash, to: rel) }
        #expect(fm.exists(trash))
    }
}

import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct PrepTests {
    @Test func prepNotes() throws {
        // A pasted agenda comes in as its points, without what they were listed with.
        #expect(prepLines("Pricing\n\n- Renewal terms\n  * Who signs?\n3. Timeline\n4) Budget\n• Risks\n- [ ] Send the deck\n[x] Done already\n   \n") ==
            ["Pricing", "Renewal terms", "Who signs?", "Timeline", "Budget", "Risks", "Send the deck", "Done already"])
        // What only looks like a list marker is part of the point.
        #expect(prepLines("-5% on renewal\r\n2026 plan\n3.5x growth") == ["-5% on renewal", "2026 plan", "3.5x growth"])
        #expect(prepLines(" \n") == [])

        // Kept per calendar event (or for a call that isn't from the calendar) until it's recorded.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-prep-\(UUID().uuidString)/prep.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(PrepNotes.load("a@2026-11-12T10:00:00.000Z", from: file) == [])
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        try PrepNotes.save("a@2026-11-12T10:00:00.000Z", [" Pricing ", "", "Who signs?"], to: file, now: then)
        try PrepNotes.save(nil, ["Ask about the rota"], to: file, now: then.addingTimeInterval(86_400))
        #expect(PrepNotes.load("a@2026-11-12T10:00:00.000Z", from: file) == ["Pricing", "Who signs?"])
        #expect(PrepNotes.load(nil, from: file) == ["Ask about the rota"])
        #expect(PrepNotes.load("b@2026-11-12T10:00:00.000Z", from: file) == [])
        // Prep for a call that was never recorded goes after a month, when something else is saved.
        try PrepNotes.save("b@2026-11-12T10:00:00.000Z", ["Budget"], to: file, now: then.addingTimeInterval(30.5 * 86_400))
        #expect(PrepNotes.load("a@2026-11-12T10:00:00.000Z", from: file) == [])
        #expect(PrepNotes.load(nil, from: file) == ["Ask about the rota"])
        // Saving none forgets it, and the file goes with the last of them.
        try PrepNotes.save(nil, [], to: file, now: then.addingTimeInterval(31 * 86_400))
        try PrepNotes.save("b@2026-11-12T10:00:00.000Z", [], to: file, now: then.addingTimeInterval(31 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Prep follows its call when the call moves within its day, and prep saved by an earlier version is still found.
    @Test func prepFollowsACallThatMoves() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-prep-\(UUID().uuidString)/prep.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // An event's id is its UID and its start. Midday here, so an hour later is the same day wherever this runs.
        let noon = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let id = { (uid: String, start: Date) in "\(uid)@\(isoString(start))" }
        try PrepNotes.save(id("weekly@google.com", noon), ["Pricing"], to: file)
        #expect(PrepNotes.load(id("weekly@google.com", noon.addingTimeInterval(3600)), from: file) == ["Pricing"])
        // Next week's occurrence, and another event at the same time, have their own.
        #expect(PrepNotes.load(id("weekly@google.com", noon.addingTimeInterval(7 * 86_400)), from: file) == [])
        #expect(PrepNotes.load(id("other@google.com", noon), from: file) == [])
        // Saved again after the move: still one entry for that call.
        try PrepNotes.save(id("weekly@google.com", noon.addingTimeInterval(3600)), ["Pricing", "Timeline"], to: file)
        #expect(PrepNotes.load(id("weekly@google.com", noon), from: file) == ["Pricing", "Timeline"])
        #expect(try readJSON([String: PrepNotes.Entry].self, file).count == 1)

        // As 0.4.1 kept it: under the whole id.
        let old = id("old@google.com", noon)
        try encodeJSON([old: PrepNotes.Entry(notes: ["From before"], savedAt: isoString(Date()))]).write(to: file, atomically: true, encoding: .utf8)
        #expect(PrepNotes.load(old, from: file) == ["From before"])
        try PrepNotes.save(old, ["From before", "And now"], to: file)
        #expect(PrepNotes.load(old, from: file) == ["From before", "And now"])
        #expect(try readJSON([String: PrepNotes.Entry].self, file).keys.map { $0 } == [PrepNotes.key(old)])
        // Something that isn't an event's id is kept under itself.
        #expect(PrepNotes.key(nil) == "" && PrepNotes.key("just-a-name") == "just-a-name")
    }
}

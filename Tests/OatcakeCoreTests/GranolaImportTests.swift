import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct GranolaImportTests {
    @Test func csv() {
        let rows = parseCsv("a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"multi\nline\"\n\n")
        #expect(rows == [["a", "b", "c"], ["x, y", "he said \"hi\"", "multi\nline"]])
    }

    /// A note that can't be written (a title too long for a folder name) is passed over, and the ones after it still come in.
    @Test func carriesOnPastANoteItCannotWrite() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-granola-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let export = work.appendingPathComponent("export.csv"), root = work.appendingPathComponent("Meetings")
        try """
            document_id,document_title,document_created,summary,transcript,notes
            aaaaaaaa-1111-1111-1111-111111111111,Review,2026-01-01T12:00:00.000Z,Went well.,,
            bbbbbbbb-2222-2222-2222-222222222222,\(String(repeating: "x", count: 300)),2026-01-02T12:00:00.000Z,Too long.,,
            cccccccc-3333-3333-3333-333333333333,Retro,2026-01-03T12:00:00.000Z,Done.,,

            """.write(to: export, atomically: true, encoding: .utf8)
        let first = try importGranola(export, into: root)
        #expect(first.imported == 2 && first.unreadable == 1)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Granola").path).count == 2)
        let again = try importGranola(export, into: root)
        #expect(again.imported == 0 && again.skipped == 2 && again.unreadable == 1)
    }

    /// An export as Granola makes it (its column names; the notes are made up): each note becomes a
    /// meeting, notes that share a title share a folder, and what's already here is skipped, from the
    /// CSV or from the .zip it comes in.
    @Test func importsAnExport() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-granola-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let exportFolder = work.appendingPathComponent("export"), root = work.appendingPathComponent("Meetings")
        try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let csv = exportFolder.appendingPathComponent("granola-export-000.csv")
        // With the byte-order mark a spreadsheet leaves at the start.
        try ("\u{FEFF}" + """
            document_id,user_email,document_title,document_created,summary,notes,transcript
            aaaaaaaa-1111-1111-1111-111111111111,sam@example.com,Weekly sync,2026-01-05T12:00:00.000Z,"## Decisions\n- Ship on the 4th",My own point,"Hello there
            Shall we start?"
            bbbbbbbb-2222-2222-2222-222222222222,sam@example.com,Weekly sync,2026-01-12T12:00:00.000Z,Short one.,,
            cccccccc-3333-3333-3333-333333333333,sam@example.com,,2026-01-13T12:00:00.000Z,No title.,,
            not-an-id,sam@example.com,Broken,2026-01-14T12:00:00.000Z,x,,
            dddddddd-4444-4444-4444-444444444444,sam@example.com,No date,soon,x,,

            """).write(to: csv, atomically: true, encoding: .utf8)

        let first = try importGranola(csv, into: root)
        #expect(first.imported == 3 && first.skipped == 0 && first.unreadable == 2 && first.folder == "Granola")
        let date = { (iso: String) in parseISO(iso)! }
        let weekly = root.appendingPathComponent("Granola/Weekly sync/" + meetingFolderName(title: "Weekly sync", startedAt: date("2026-01-05T12:00:00Z")))
        #expect(readText(weekly.appendingPathComponent("summary.md")) == "## Decisions\n- Ship on the 4th\n")
        #expect(readText(weekly.appendingPathComponent("transcript.md")) == "Hello there\n\nShall we start?\n")
        #expect(readText(weekly.appendingPathComponent("notes.md")) == "My own point\n")
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: weekly.appendingPathComponent("meeting.json"))) as? [String: String]
        #expect(meta == ["title": "Weekly sync", "startedAt": "2026-01-05T12:00:00.000Z", "source": "granola", "granolaNote": "https://notes.granola.ai/d/aaaaaaaa-1111-1111-1111-111111111111"])
        // Granola kept no notes for the second: no notes.md. A note on its own isn't in a series folder.
        let second = root.appendingPathComponent("Granola/Weekly sync/" + meetingFolderName(title: "Weekly sync", startedAt: date("2026-01-12T12:00:00Z")))
        #expect(fm.fileExists(atPath: second.appendingPathComponent("summary.md").path) && !fm.fileExists(atPath: second.appendingPathComponent("notes.md").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Granola/" + meetingFolderName(title: "Untitled", startedAt: date("2026-01-13T12:00:00Z"))).path))

        // The .zip Granola gives you, after one of the meetings has been moved somewhere else.
        try Meetings(root: root).move("Granola/Weekly sync", into: "")
        let zip = work.appendingPathComponent("export.zip")
        try runCapturing("/usr/bin/ditto", ["-c", "-k", exportFolder.path, zip.path])
        // Progress is reported from wherever the import runs, so what it says is collected behind a lock.
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func add(_ value: Int) { lock.withLock { values.append(value) } }
            var all: [Int] { lock.withLock { values } }
        }
        let seen = Seen()
        let again = try importGranola(zip, into: root) { done, total in seen.add(done * 100 + total) }
        #expect(again.imported == 0 && again.skipped == 3 && again.unreadable == 2)
        #expect(seen.all == [5, 105, 205, 305, 405, 505])

        // Something that isn't an export says so.
        let other = work.appendingPathComponent("other.csv")
        try "name,email\nSam,sam@example.com\n".write(to: other, atomically: true, encoding: .utf8)
        #expect(throws: OatcakeError.self) { try importGranola(other, into: root) }
        #expect(throws: OatcakeError("Pick the .zip (or .csv) that Granola's export gave you.")) { try importGranola(work.appendingPathComponent("export.txt"), into: root) }
    }
}

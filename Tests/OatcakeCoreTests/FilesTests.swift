import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct FilesTests {
    /// A file is replaced whole, and never written through: a link where the file should be is
    /// replaced, and what it pointed at is left alone.
    @Test func writesWholeAndNeverThroughALink() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("summary.md")
        try writeAtomic(file, "first")
        try writeAtomic(file, "second", permissions: 0o600)
        #expect(readText(file) == "second")
        #expect(((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int) == 0o600)
        // Nothing is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path) == ["summary.md"])

        let elsewhere = tmp.appendingPathComponent("elsewhere.txt"), link = tmp.appendingPathComponent("todo.md")
        try "untouched".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        try writeAtomic(link, "- [ ] Mine")
        #expect(readText(elsewhere) == "untouched")
        #expect(readText(link) == "- [ ] Mine")
        #expect(((try FileManager.default.attributesOfItem(atPath: link.path))[.type] as? FileAttributeType) == .typeRegular)
        // A folder that isn't there: said, and nothing made.
        #expect(throws: OatcakeError.self) { try writeAtomic(tmp.appendingPathComponent("no/such/file.md"), "x") }
    }

    @Test func pathsStayInside() throws {
        let root = URL(fileURLWithPath: "/tmp/Meetings")
        #expect(try resolveInside(root, "Team/2026-11-05 1400 Weekly sync").path == "/tmp/Meetings/Team/2026-11-05 1400 Weekly sync")
        #expect(try resolveInside(root, "").path == "/tmp/Meetings")
        for outside in ["..", "../Meetings2", "Team/../../etc", "Team/../.."] {
            #expect(throws: OatcakeError.self) { try resolveInside(root, outside) }
        }
        #expect(relativePath(URL(fileURLWithPath: "/tmp/Meetings/Team/x"), to: root) == "Team/x")
        #expect(relativePath(root, to: root) == "")
    }

    /// A file with a byte that isn't UTF-8 is read as far as it can be, not as nothing.
    @Test func readsWhatItCan() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-read-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        try (Data("- [ ] Send the deck ".utf8) + Data([0xFF]) + Data("\n".utf8)).write(to: file)
        #expect(readText(file).hasPrefix("- [ ] Send the deck "))
        #expect(readText(file.appendingPathExtension("missing")) == "")
        #expect(parseISO("2026-11-05T14:00:02.682Z") != nil && parseISO("2026-11-05T14:00:02Z") != nil && parseISO("soon") == nil && parseISO(nil) == nil)
    }
}

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

    /// Links are followed: one that leads out of the folder, nowhere, or round in a loop is refused,
    /// one that leads to another place inside it isn't, and the folder itself can be a link.
    @Test func pathsStayInsideThroughLinks() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-links-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let real = tmp.appendingPathComponent("Meetings")
        try fm.createDirectory(at: real.appendingPathComponent("Team"), withIntermediateDirectories: true)
        let root = tmp.appendingPathComponent("Chosen")
        try fm.createSymbolicLink(atPath: root.path, withDestinationPath: "Meetings")
        for (name, target) in [("Out", ".."), ("Nowhere", "Missing"), ("Loop", "Loop"), ("In", "Team")] {
            try fm.createSymbolicLink(atPath: real.appendingPathComponent(name).path, withDestinationPath: target)
        }
        for inside in ["", "Team", "In", "In/2026-11-05 1400 Weekly sync", "Not there yet/Weekly sync"] {
            #expect(try resolveInside(root, inside).path == root.appendingPathComponent(inside).standardizedFileURL.path)
        }
        for outside in ["Out", "Out/Meetings/Team", "Nowhere", "Nowhere/Weekly sync", "Loop"] {
            #expect(throws: OatcakeError.self) { try resolveInside(root, outside) }
        }
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

import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct QuillTests {
    /// A tiny backup in Quill's shape: two meetings with the same title, one with a named voice, notes and a recording.
    @Test func importsBackup() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-quill-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let src = work.appendingPathComponent("backup"), root = work.appendingPathComponent("Meetings")
        let a = "11111111-1111-1111-1111-111111111111", b = "22222222-2222-2222-2222-222222222222"
        let audioDir = src.appendingPathComponent("meetings/1767268800000-\(a)")
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // A partial take sorts first by name; the finished one is still the one imported.
        try Data("partial".utf8).write(to: audioDir.appendingPathComponent("\(a)-1767268800.000000-combined.m4a"))
        try Data("combined".utf8).write(to: audioDir.appendingPathComponent("\(a)-FINAL-1767268800.000000-1767268870.000000-combined.m4a"))
        try Data("mic".utf8).write(to: audioDir.appendingPathComponent("\(a)-FINAL-mic.m4a"))
        let transcript = #"{"blocks":[{"from":1767268801000,"to":1767268802000,"text":"Morning.","source":"system","speaker_id":"S1"},{"from":1767268803000,"to":1767268804000,"text":"Hi Sam.","source":"mic","speaker_id":"S2"},{"from":1767268810000,"to":1767268811000,"text":"Who's that?","source":"system","speaker_id":"S3"}]}"#
        _ = try runCapturing("/usr/bin/sqlite3", [src.appendingPathComponent("quill.db").path, """
            CREATE TABLE Meeting (id TEXT, start DATETIME, "end" DATETIME, audio_transcript TEXT, title TEXT, folder TEXT,
                deleteDate DATETIME, hidden BOOLEAN, eventTitle TEXT, manualTitle TEXT);
            CREATE TABLE Note (id TEXT, meeting_id TEXT, title TEXT, body TEXT, createdAt DATETIME);
            CREATE TABLE ContactMeeting (contact_id TEXT, speaker_id TEXT, meeting_id TEXT, suggested_name TEXT);
            CREATE TABLE Contact (id TEXT, name TEXT);
            INSERT INTO Meeting VALUES ('\(a)', 1767268800000, 1767268870000, '\(transcript.replacingOccurrences(of: "'", with: "''"))', 'Planning', '1767268800000-\(a)', NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('\(b)', 1767355200000, NULL, '{"blocks":[{"from":1767355201000,"to":1767355202000,"text":"Hello.","source":"mic"}]}', 'Planning', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('33333333-3333-3333-3333-333333333333', 1767441600000, NULL, NULL, 'Deleted', NULL, 1767445200000, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('44444444-4444-4444-4444-444444444444', 1767441600000, NULL, NULL, 'Hidden', NULL, NULL, 1, NULL, NULL);
            INSERT INTO Note VALUES ('n1', '\(a)', 'Minutes', '## Plans &amp; dates' || char(10) || char(10) || '#### 2m' || char(10) || '- Ship it', 1);
            INSERT INTO Contact VALUES ('c1', 'Sam Lee');
            INSERT INTO ContactMeeting VALUES ('c1', 'S1', '\(a)', NULL);
            """])
        let zip = work.appendingPathComponent("QuillBackup.zip")
        _ = try runCapturing("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])

        let first = try importQuill(zip, into: root, me: "Alex")
        // The deleted and the hidden meeting are left out altogether: not imported, skipped or unreadable.
        #expect(first.imported == 2 && first.skipped == 0 && first.unreadable == 0)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Quill").path) == ["Planning"])
        let series = root.appendingPathComponent("Quill/Planning")
        let folders = try fm.contentsOfDirectory(atPath: series.path).sorted()
        #expect(folders.count == 2)
        let meeting = series.appendingPathComponent(folders[0])
        #expect(readText(meeting.appendingPathComponent("transcript.md")) ==
                "**[00:01] Sam Lee:** Morning.\n\n**[00:03] Alex:** Hi Sam.\n\n**[00:10] Voice 1:** Who's that?\n")
        #expect(readText(meeting.appendingPathComponent("summary.md")) == "## Plans & dates\n\n- Ship it\n")
        #expect(readText(meeting.appendingPathComponent("audio.m4a")) == "combined")
        let meta = try JSONDecoder().decode(MeetingMeta.self, from: Data(contentsOf: meeting.appendingPathComponent("meeting.json")))
        #expect(meta.title == "Planning" && meta.source == "quill" && meta.participants == ["Sam Lee", "Alex"] && meta.endedAt != nil)
        // The meeting without a recording or notes still comes in, with just its transcript and meeting.json.
        #expect(try fm.contentsOfDirectory(atPath: series.appendingPathComponent(folders[1]).path).sorted() == ["meeting.json", "transcript.md"])

        let again = try importQuill(zip, into: root, me: "Alex")
        #expect(again.imported == 0 && again.skipped == 2)
    }

    /// What a real backup may hold that a tidy one doesn't: rows that belong to nothing, a transcript
    /// block that's malformed, several notes on one meeting, and a meeting that can't be written.
    @Test func survivesAnUntidyBackup() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("oatcake-quill-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let src = work.appendingPathComponent("backup"), root = work.appendingPathComponent("Meetings")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let a = "aaaaaaaa-1111-1111-1111-111111111111", b = "bbbbbbbb-2222-2222-2222-222222222222", c = "cccccccc-3333-3333-3333-333333333333"
        // The second block has no text and the third isn't a block at all.
        let transcript = #"{"blocks":[{"from":1767268801000,"to":1767268802000,"text":"Morning.","source":"system","speaker_id":"S1"},{"from":1767268803000,"text":null},null,{"from":1767268805000,"text":"Shall we start?","source":"mic"}]}"#
        _ = try runCapturing("/usr/bin/sqlite3", [src.appendingPathComponent("quill.db").path, """
            CREATE TABLE Meeting (id TEXT, start DATETIME, "end" DATETIME, audio_transcript TEXT, title TEXT, folder TEXT,
                deleteDate DATETIME, hidden BOOLEAN, eventTitle TEXT, manualTitle TEXT);
            CREATE TABLE Note (id TEXT, meeting_id TEXT, title TEXT, body TEXT, createdAt DATETIME);
            CREATE TABLE ContactMeeting (contact_id TEXT, speaker_id TEXT, meeting_id TEXT, suggested_name TEXT);
            CREATE TABLE Contact (id TEXT, name TEXT);
            INSERT INTO Meeting VALUES ('\(a)', 1767268800000, 1767268870000, '\(transcript)', 'Review', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('\(b)', 1767355200000, NULL, '{"blocks":[{"from":1767355201000,"to":1767355202000,"text":"Hello.","source":"mic"}]}', '\(String(repeating: "x", count: 300))', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('\(c)', 1767441600000, NULL, '{"blocks":[{"from":1767441601000,"to":1767441602000,"text":"Right.","source":"mic"}]}', 'Retro', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Meeting VALUES ('dddddddd-4444-4444-4444-444444444444', 1798761600000, NULL, NULL, 'Dentist', NULL, NULL, NULL, NULL, NULL);
            INSERT INTO Note VALUES ('n1', '\(a)', 'Minutes', '- **Decision:** ship Friday' || char(10) || '- **Owner:** Sam', 1);
            INSERT INTO Note VALUES ('n2', '\(a)', 'Follow-ups', 'Book the room.', 2);
            INSERT INTO Note VALUES ('n3', '\(a)', 'Empty', '', 3);
            INSERT INTO Note VALUES ('n4', NULL, 'Belongs to nothing', 'Lost.', 4);
            INSERT INTO Contact VALUES ('c1', 'Sam Lee');
            INSERT INTO ContactMeeting VALUES ('c1', 'S1', '\(a)', NULL);
            INSERT INTO ContactMeeting VALUES ('c1', NULL, '\(a)', NULL);
            INSERT INTO ContactMeeting VALUES ('c1', 'S9', NULL, NULL);
            """])
        let zip = work.appendingPathComponent("QuillBackup.zip")
        _ = try runCapturing("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])

        // The meeting whose title is too long for a folder name is passed over; the one after it still comes in.
        // The row with nothing in it (no words, notes or recording) isn't a meeting, and isn't counted.
        let first = try importQuill(zip, into: root, me: "Alex")
        #expect(first.imported == 2 && first.skipped == 0 && first.unreadable == 1)
        let quill = root.appendingPathComponent("Quill")
        let folders = try fm.contentsOfDirectory(atPath: quill.path).sorted()
        #expect(folders.count == 2 && folders[0].hasSuffix("Review") && folders[1].hasSuffix("Retro"))
        // The blocks that are whole are kept.
        #expect(readText(quill.appendingPathComponent("\(folders[0])/transcript.md")) == "**[00:01] Sam Lee:** Morning.\n\n**[00:05] Alex:** Shall we start?\n")
        // Each note that has something in it under its title, at a level the meeting view keeps.
        let summary = readText(quill.appendingPathComponent("\(folders[0])/summary.md"))
        #expect(summary == "## Minutes\n\n- **Decision:** ship Friday\n- **Owner:** Sam\n\n## Follow-ups\n\nBook the room.\n")
        #expect(forReading(summary) == summary)
        // A lone note with something in it needs no heading, whatever empty ones sit beside it.
        #expect(quillSummary([(title: "Empty", body: " "), (title: "Minutes", body: "Shipped.")]) == "Shipped.\n")
        // Again: the two are already here, and the third is still passed over rather than stopping the import.
        let again = try importQuill(zip, into: root, me: "Alex")
        #expect(again.imported == 0 && again.skipped == 2 && again.unreadable == 1)

        // A .zip that isn't one, and one that isn't Quill's backup, are each said to be what they are.
        let broken = work.appendingPathComponent("Broken.zip")
        try Data("not a zip".utf8).write(to: broken)
        #expect(throws: OatcakeError("That .zip couldn’t be opened. It may be incomplete or damaged.")) { try importQuill(broken, into: root, me: "Alex") }
        let other = work.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: other.appendingPathComponent("readme.txt"))
        _ = try runCapturing("/usr/bin/ditto", ["-c", "-k", other.path, work.appendingPathComponent("Other.zip").path])
        #expect(throws: OatcakeError("That .zip has no quill.db at its top level. Is it the backup as Quill made it?")) {
            try importQuill(work.appendingPathComponent("Other.zip"), into: root, me: "Alex")
        }
    }

    @Test func transcriptAndNotesAsWritten() {
        // Lines come out in the order they were said, whatever order the backup has them in, and ones
        // from before the meeting's start time keep their spacing rather than all landing on 00:00.
        let blocks = #"{"blocks":[{"from":70000,"to":71000,"text":"Third.","source":"system","speaker_id":"S2"},{"from":1000,"to":2000,"text":"First.","source":"system","speaker_id":"S1"},{"from":40000,"to":41000,"text":"Second.","source":"mic"}]}"#
        #expect(quillTranscript(blocks, start: 60000, me: "Alex", names: [:]).markdown == "**[00:00] Voice 1:** First.\n\n**[00:39] Alex:** Second.\n\n**[01:09] Voice 2:** Third.\n")
        // A time no call could have (a damaged backup) is read without stopping the import.
        let damaged = #"{"blocks":[{"from":1000,"to":2000,"text":"First.","source":"mic"},{"from":1e300,"to":1e300,"text":"Late.","source":"mic"}]}"#
        #expect(quillTranscript(damaged, start: 0, me: "Alex", names: [:]).markdown == "**[00:01] Alex:** First.\n\n**[99:59:59] Alex:** Late.\n")
        // Quill's minute markers go and the paragraph break around them stays; a heading of your own is kept.
        #expect(quillSummary([(title: nil, body: "First point\n#### 2m\n\nSecond point\n#### 1h 2m\nThird\n\n### 5m\nFourth")]) == "First point\n\nSecond point\nThird\n\n### 5m\nFourth\n")
    }
}

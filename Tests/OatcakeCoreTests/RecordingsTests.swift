import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct RecordingsTests {
    /// Once a call is saved as a meeting its working folder goes. Audio that was kept goes into the
    /// meeting first, as one file to listen to, wherever the meeting has been moved to since.
    @Test func savedRecordingsAreClearedAway() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-tidy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        /// A tone, as the recorder writes a track: 16 kHz, 16-bit, one channel. Made here.
        func tone(_ seconds: Double, hz: Double) -> Data {
            let samples = (0..<Int(seconds * Double(sampleRate))).map { Int16(8000 * sin(2 * .pi * hz * Double($0) / Double(sampleRate))).littleEndian }
            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        func recording(_ id: String, saved: String?, audio: Bool) throws -> URL {
            let dir = recordings.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"title":"Call","startedAt":"2026-11-10T14:00:00.000Z"}"#.write(to: dir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
            if let saved { try encodeJSON(["meeting": saved]).write(to: dir.appendingPathComponent("saved.json"), atomically: true, encoding: .utf8) }
            if audio {
                // You for a second from the start; the call for a second and a half, from half a second in.
                try tone(1, hz: 440).write(to: dir.appendingPathComponent("mic.pcm"))
                try tone(1.5, hz: 660).write(to: dir.appendingPathComponent("system.pcm"))
                try #"{"startedAt":"2026-11-10T14:00:00.000Z","endedAt":"2026-11-10T14:00:02.000Z","sampleRate":16000,"micOffset":0,"systemOffset":0.5}"#
                    .write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
            }
            return dir
        }
        func meeting(_ rel: String, recording id: String) throws -> URL {
            let dir = root.appendingPathComponent(rel)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"title":"Call","recording":"\#(id)"}"#.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
            return dir
        }
        let plain = try recording("r1", saved: "2026-11-10 1400 One", audio: false)
        let kept = try recording("r2", saved: "2026-11-10 1400 Two", audio: true)
        let orphan = try recording("r3", saved: "2026-11-10 1400 Three", audio: true)
        let waiting = try recording("r4", saved: nil, audio: true)
        _ = try meeting("2026-11-10 1400 One", recording: "r1")
        // Saved as "…Two" at the top level, and moved into a folder and renamed since.
        let two = try meeting("Clients/2026-11-10 1400 Second", recording: "r2")
        let rec = { (dir: URL) in Recording(id: dir.lastPathComponent, dir: dir, title: "Call", startedAt: Date(), state: .saved) }
        #expect(Recordings.hasAudio(rec(kept)) && !Recordings.hasAudio(rec(plain)))

        Recordings.tidySaved(meetingsRoot: root, recordings: recordings)
        // Nothing kept: gone. Audio kept: in its meeting, then gone. No meeting to put it in, or not saved yet: left alone.
        #expect(try fm.contentsOfDirectory(atPath: recordings.path).sorted() == ["r3", "r4"])
        #expect(Recordings.hasAudio(rec(orphan)) && Recordings.hasAudio(rec(waiting)))
        let audio = try AVAudioFile(forReading: two.appendingPathComponent("audio.m4a"))
        #expect(abs(Double(audio.length) / audio.fileFormat.sampleRate - 2.0) < 0.1)
        #expect(try fm.contentsOfDirectory(atPath: two.path).sorted() == ["audio.m4a", "meeting.json"])
    }

    /// A recordings folder for a test, and a recording's folder in it holding the files named.
    private func folder() throws -> URL {
        let recordings = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        return recordings
    }

    private func make(_ id: String, in recordings: URL, title: String = "Weekly sync", files: [String: String] = [:]) throws -> URL {
        let dir = recordings.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodeJSON(CallInfo(title: title, folder: "Team", startedAt: "2026-11-10T14:00:00.000Z", eventId: "e1", attendees: ["Alex"]))
            .write(to: dir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }

    /// Where a recording has got to is read from which files its folder holds.
    @Test func statesFromFiles() throws {
        let recordings = try folder()
        defer { try? FileManager.default.removeItem(at: recordings) }
        let meta = try encodeJSON(RecorderMeta(startedAt: "2026-11-10T14:00:00Z", endedAt: "2026-11-10T14:30:00Z", micOffset: 0.2, systemOffset: 0.1))
        _ = try make("2026-11-10T14-00-00-000Z", in: recordings)
        _ = try make("2026-11-11T14-00-00-000Z", in: recordings, files: ["meta.json": meta])
        _ = try make("2026-11-12T14-00-00-000Z", in: recordings, files: ["meta.json": meta, "analysis.json": "{}"])
        _ = try make("2026-11-13T14-00-00-000Z", in: recordings, files: ["meta.json": meta, "analysis.json": "{}", "saved.json": "{}"])
        // One damaged call.json hides that recording, not the others.
        let damaged = try make("2026-11-14T14-00-00-000Z", in: recordings)
        try "{ cut short".write(to: damaged.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)

        let all = Recordings.list(recordings: recordings)
        // Newest first.
        #expect(all.map(\.state) == [.saved, .processed, .recorded, .recording])
        #expect(all.first?.id == "2026-11-13T14-00-00-000Z" && all.first?.folder == "Team" && all.first?.attendees == ["Alex"])
        #expect(all.first?.endedAt == parseISO("2026-11-10T14:30:00Z") && all.last?.endedAt == nil)
        #expect(Recordings.get("2026-11-11T14-00-00-000Z", recordings: recordings)?.state == .recorded)
        #expect(Recordings.get("2026-11-14T14-00-00-000Z", recordings: recordings) == nil)
        #expect(Recordings.list(recordings: recordings.appendingPathComponent("nowhere")).isEmpty)
    }

    /// Notes are kept by the recording's ID, which is only ever its start time: nothing else names a folder.
    @Test func notesAndIds() throws {
        let recordings = try folder()
        defer { try? FileManager.default.removeItem(at: recordings) }
        let id = "2026-11-10T14-00-00-000Z"
        let dir = try make(id, in: recordings)
        try Recordings.saveNotes(id, [Note(at: nil, text: "Ask about the budget"), Note(at: 12.5, text: "Agreed")], recordings: recordings)
        // A prep note's time is written as null, not left out.
        #expect(readText(dir.appendingPathComponent("notes.json")).contains("\"at\" : null"))
        #expect(Recordings.loadNotes(id, recordings: recordings) == [Note(at: nil, text: "Ask about the budget"), Note(at: 12.5, text: "Agreed")])
        #expect(Recordings.loadNotes("2026-11-10T15-00-00-000Z", recordings: recordings).isEmpty)
        for bad in ["../\(id)", "notes", "2026-11-10T14-00-00-000Z/..", ""] {
            #expect(throws: OatcakeError("Recording not found")) { try Recordings.dir(bad, recordings: recordings) }
            #expect(throws: OatcakeError("Recording not found")) { try Recordings.saveNotes(bad, [], recordings: recordings) }
            #expect(throws: OatcakeError("Recording not found")) { try Recordings.discard(bad, recordings: recordings) }
        }
        try Recordings.discard(id, recordings: recordings)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// A recorder that went without finishing: what it captured is kept, and its offsets are marked as a guess.
    @Test func recorderThatNeverFinished() throws {
        let recordings = try folder()
        defer { try? FileManager.default.removeItem(at: recordings) }
        let id = "2026-11-10T14-00-00-000Z"
        // Its pid file names a process that isn't a recorder (this one), as after a crash and a reused ID.
        let dir = try make(id, in: recordings, files: ["recorder.pid": String(getpid())])
        let rec = try #require(Recordings.get(id, recordings: recordings))
        #expect(rec.state == .recording && !Recordings.isRunning(rec) && !Recordings.hasAudio(rec))
        try Data(count: 3200).write(to: dir.appendingPathComponent("mic.pcm"))
        #expect(Recordings.hasAudio(rec))

        Recordings.finishInterrupted(rec)
        let meta = try readJSON(RecorderMeta.self, dir.appendingPathComponent("meta.json"))
        #expect(meta.interrupted == true && meta.micOffset == 0 && meta.systemOffset == 0 && meta.startedAt == isoString(rec.startedAt))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("recorder.pid").path))
        #expect(Recordings.get(id, recordings: recordings)?.state == .recorded)
        // Done once: a meta.json that's there is left as it is.
        try "{}".write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        Recordings.finishInterrupted(rec)
        #expect(readText(dir.appendingPathComponent("meta.json")) == "{}")
    }
}

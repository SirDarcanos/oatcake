import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct AudioTests {
    @MainActor @Test func savedAudioPlayback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("audio.m4a")
        let player = RecordingPlayback()
        defer { player.stop() }
        player.toggle(file)
        #expect(player.failure == .missingFile && !player.isPlaying && player.duration == 0)
        try Data("not audio".utf8).write(to: file)
        player.toggle(file)
        #expect(player.failure == .unreadableFile && !player.isPlaying && player.duration == 0)

        try FileManager.default.removeItem(at: file)
        try Data(count: 2 * sampleRate * 5).write(to: dir.appendingPathComponent("mic.pcm"))
        try exportAudio(recording: dir, to: file)
        // Opened without playing: its length is there for the transcript's times.
        let prepared = RecordingPlayback()
        prepared.prepare(file)
        #expect(prepared.failure == nil && !prepared.isPlaying && abs(prepared.duration - 5) < 0.25)
        prepared.seek(to: 3)
        prepared.toggle(file)
        #expect(prepared.isPlaying && prepared.elapsed >= 2.85)
        prepared.stop()
        player.toggle(file)
        #expect(player.failure == nil && player.isPlaying && abs(player.duration - 5) < 0.25)
        player.toggle(file)
        #expect(!player.isPlaying)
        player.seek(to: 2)
        player.refreshPosition()
        #expect(abs(player.elapsed - 2) < 0.15)
        player.toggle(file)
        #expect(player.isPlaying && player.elapsed >= 1.85)

        let line = try #require(parseTranscript("**[00:04] Jane Doe:** Pick up here.").first)
        player.seek(to: line.at)
        player.refreshPosition()
        #expect(player.isPlaying && abs(player.elapsed - 4) < 0.15)

        player.seek(to: player.duration - 0.25)
        let deadline = ContinuousClock.now + .seconds(4)
        while player.isPlaying && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(!player.isPlaying && player.failure == nil)
        #expect(player.elapsed == player.duration)
        player.toggle(file)
        #expect(player.isPlaying && player.elapsed == 0)
        player.refreshPosition()
        #expect(player.elapsed < 1)

        player.toggle(file)
        try FileManager.default.removeItem(at: file)
        player.toggle(file)
        #expect(player.failure == .missingFile && !player.isPlaying)
        player.stop()
        #expect(player.failure == nil && !player.isPlaying && player.duration == 0 && player.elapsed == 0)
    }

    /// Keeping a call's audio fails out loud, and leaves nothing half-written behind.
    @Test func keptAudioFailures() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-export-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let meeting = tmp.appendingPathComponent("Meeting")
        try fm.createDirectory(at: meeting, withIntermediateDirectories: true)
        let audio = meeting.appendingPathComponent("audio.m4a")
        #expect(throws: OatcakeError("This call has no audio to keep.")) { try exportAudio(recording: tmp, to: audio) }

        try Data(count: 2 * sampleRate).write(to: tmp.appendingPathComponent("mic.pcm"))
        // Nowhere to write it: the meeting's folder has gone.
        #expect(throws: (any Error).self) { try exportAudio(recording: tmp, to: tmp.appendingPathComponent("Gone/audio.m4a")) }
        // Written whole, then not put in place: what's there already stays, and the copy being written goes.
        try Data("already here".utf8).write(to: audio)
        #expect(throws: (any Error).self) { try exportAudio(recording: tmp, to: audio) }
        #expect(try fm.contentsOfDirectory(atPath: meeting.path) == ["audio.m4a"] && readText(audio) == "already here")
    }

    /// The recorder's raw tracks are read as they were written, whole or from where the last read stopped, and a clip is a proper WAV file.
    @Test func tracksAndClips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Two seconds of made-up samples: a ramp, so every one is different.
        let samples = (0..<2 * sampleRate).map { Int16(truncatingIfNeeded: $0 - 16_000) }
        let track = tmp.appendingPathComponent("mic.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: track)

        let read = try readPcm(track)
        #expect(read.count == samples.count && read[0] == Float(samples[0]) / 32768 && read[20_000] == Float(samples[20_000]) / 32768)
        #expect(readPcm(track, fromSample: 30_000) == Array(read[30_000...]))
        #expect(readPcm(track, fromSample: 30_000, count: 1_000) == Array(read[30_000..<31_000]))
        #expect(readPcm(track, fromSample: samples.count).isEmpty)
        // A track that isn't there is an error to an analysis, not silence; to the live transcript it's
        // only not there yet. One that's there with nothing in it is empty.
        let none = tmp.appendingPathComponent("none.pcm")
        #expect(throws: CocoaError.self) { try readPcm(none) }
        #expect(readPcm(none, fromSample: 0).isEmpty)
        try Data().write(to: none)
        #expect(try readPcm(none).isEmpty)
        // A stretch of a mapped track is the same as the same stretch of the whole of it.
        let mapped = try PcmFile(track)
        #expect(mapped.count == samples.count && mapped.samples(0.5, 1.5) == Array(slice(read, 0.5, 1.5)))
        #expect(mapped.samples(-1, 0.25).count == 4_000 && mapped.samples(1.9, 9) == Array(slice(read, 1.9, 9)) && mapped.samples(5, 6).isEmpty)

        // Half a second to a second and a half; times past either end are brought back to it.
        #expect(Array(slice(read, 0.5, 1.5)) == Array(read[8_000..<24_000]))
        #expect(slice(read, -1, 0.25).count == 4_000 && slice(read, 1.9, 9).count == 1_600 && slice(read, 5, 6).isEmpty)

        let clip = tmp.appendingPathComponent("A-1.wav")
        try writeWav(clip, slice(read, 0.5, 1.5))
        let wav = try Data(contentsOf: clip)
        #expect(wav.count == 44 + 16_000 * 2)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF" && String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt " && String(decoding: wav[36..<40], as: UTF8.self) == "data")
        // What macOS makes of it: one channel at 16 kHz, a second long.
        let file = try AVAudioFile(forReading: clip)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1 && file.length == 16_000)
        // The samples come back as they went in (to within the rounding of a 16-bit sample).
        let back = wav[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(back.count == 16_000 && zip(back, samples[8_000..<24_000]).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }
}

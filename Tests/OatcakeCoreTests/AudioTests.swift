import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct AudioTests {
    /// The recorder's raw tracks are read as they were written, whole or from where the last read stopped, and a clip is a proper WAV file.
    @Test func tracksAndClips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Two seconds of made-up samples: a ramp, so every one is different.
        let samples = (0..<2 * sampleRate).map { Int16(truncatingIfNeeded: $0 - 16_000) }
        let track = tmp.appendingPathComponent("mic.pcm")
        try samples.withUnsafeBytes { Data($0) }.write(to: track)

        let read = readPcm(track)
        #expect(read.count == samples.count && read[0] == Float(samples[0]) / 32768 && read[20_000] == Float(samples[20_000]) / 32768)
        #expect(readPcm(track, fromSample: 30_000) == Array(read[30_000...]))
        #expect(readPcm(track, fromSample: samples.count).isEmpty && readPcm(tmp.appendingPathComponent("none.pcm")).isEmpty)

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

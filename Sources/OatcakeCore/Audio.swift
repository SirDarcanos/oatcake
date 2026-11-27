import AVFoundation
import Foundation

public let sampleRate = recorderSampleRate

/**
 * A raw 16 kHz mono PCM16 track, mapped rather than read. Its samples are made floats (twice the
 * size) when they're wanted, and only as many as are: an hour of a track is about 115 MB as samples
 * and 230 MB as floats, so analysing a call holds one track's floats at a time, not both.
 */
struct PcmFile {
    private let data: Data

    /// Throws when the file can't be read: a track that isn't there isn't silence.
    init(_ url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    var count: Int { data.count / 2 }

    /// Every sample, as floats in [-1, 1].
    func samples() -> [Float] { floats(data) }

    /// The samples between two times in seconds, clamped to the track.
    func samples(_ start: Double, _ end: Double) -> [Float] {
        let from = max(0, min(count, Int((start * Double(sampleRate)).rounded(.down))))
        let to = max(from, min(count, Int((end * Double(sampleRate)).rounded(.up))))
        return floats(data[(data.startIndex + from * 2)..<(data.startIndex + to * 2)])
    }
}

/// Reads a raw 16 kHz mono PCM16 file into floats in [-1, 1].
func readPcm(_ url: URL) throws -> [Float] { try PcmFile(url).samples() }

/// PCM16 samples, little-endian, as floats in [-1, 1].
private func floats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
}

/// The samples of a raw PCM16 file from one sample onwards, `count` at most: what a recording still
/// being written has gained since. Nothing when the file isn't there yet.
func readPcm(_ url: URL, fromSample: Int, count: Int? = nil) -> [Float] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(fromSample) * 2)) != nil else { return [] }
    let data: Data?
    if let count { data = try? handle.read(upToCount: count * 2) } else { data = try? handle.readToEnd() }
    return data.map(floats) ?? []
}

/// The samples between two times in seconds, clamped to the track.
func slice(_ samples: [Float], _ start: Double, _ end: Double) -> ArraySlice<Float> {
    let from = max(0, min(samples.count, Int((start * Double(sampleRate)).rounded(.down))))
    let to = max(from, min(samples.count, Int((end * Double(sampleRate)).rounded(.up))))
    return samples[from..<to]
}

/// Writes floats as a 16 kHz mono PCM16 WAV file (the review screen's clips).
func writeWav(_ url: URL, _ samples: ArraySlice<Float>) throws {
    var data = Data(capacity: 44 + samples.count * 2)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + samples.count * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1) // PCM
    u16(1) // mono
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 2))
    u16(2)
    u16(16)
    data.append(contentsOf: Array("data".utf8))
    u32(UInt32(samples.count * 2))
    for s in samples {
        u16(UInt16(bitPattern: Int16((max(-1, min(1, s)) * 32767).rounded())))
    }
    try data.write(to: url)
}

/**
 * A recording's two tracks as one file to listen to: mixed to mono, each placed where meta.json
 * says it starts, as AAC in an .m4a. Read and written half a minute at a time, so an afternoon's
 * call isn't held in memory, and under another name until it's whole.
 */
func exportAudio(recording dir: URL, to file: URL) throws {
    let meta = tryJSON(RecorderMeta.self, dir.appendingPathComponent(RecorderFile.meta))
    // Each track: where to read it, how many samples in it starts, and how many it has.
    let tracks = [(RecorderFile.micTrack, meta?.micOffset ?? 0), (RecorderFile.systemTrack, meta?.systemOffset ?? 0)].compactMap { name, offset -> (handle: FileHandle, lead: Int, samples: Int)? in
        let url = dir.appendingPathComponent(name)
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64, bytes >= 2,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let lead = offset.isFinite ? Int(min(max(0, offset), 86_400) * Double(sampleRate)) : 0
        return (handle, lead, Int(bytes / 2))
    }
    defer { tracks.forEach { try? $0.handle.close() } }
    let total = tracks.map { $0.lead + $0.samples }.max() ?? 0
    guard total > 0 else { throw OatcakeError("This call has no audio to keep.") }

    let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString.prefix(12)).\(file.lastPathComponent)")
    do {
        let writer = try AVAudioFile(forWriting: tmp, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1],
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let stretch = sampleRate * 30
        var at = 0
        while at < total {
            let count = min(stretch, total - at)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  let mixed = buffer.floatChannelData?[0] else { throw OatcakeError("Couldn’t write the call’s audio.") }
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { mixed[i] = 0 }
            for track in tracks {
                // The part of this track that falls in this stretch.
                let from = max(at, track.lead), to = min(at + count, track.lead + track.samples)
                guard from < to else { continue }
                try track.handle.seek(toOffset: UInt64(from - track.lead) * 2)
                let data = try track.handle.read(upToCount: (to - from) * 2) ?? Data()
                for (i, sample) in floats(data).enumerated() { mixed[from - at + i] += sample }
            }
            // Two people talking at once can add up to more than full scale.
            for i in 0..<count { mixed[i] = max(-1, min(1, mixed[i])) }
            try writer.write(from: buffer)
            at += count
        }
        writer.close()
        try FileManager.default.moveItem(at: tmp, to: file)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

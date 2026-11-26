// The recorder's decisions, kept apart from its audio devices so they can be tested: how a track is
// written and kept lined up with the other, when a capture is started again, and when the recording
// stops by itself. The recorder (Sources/OatcakeRecorder) is top-level code in an app of its own,
// which tests can't reach.

import Foundation

/// The programs' names, as their paths end: a process ID is only believed when it's one of these.
public enum ProgramName {
    public static let app = "Oatcake"
    public static let recorder = "oatcake-recorder"
}

/// Whether a process ID is a running copy of the program whose path ends with `name`: a pid file
/// outlives its process when that crashes, and macOS gives process IDs out again.
public func isRunning(_ pid: pid_t, program name: String) -> Bool {
    guard pid > 1 else { return false }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
    return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.hasSuffix("/" + name)
}

// MARK: - Tracks

/// Where a track's samples go: its file in the recorder, memory in a test.
public protocol TrackOutput: AnyObject {
    func write(_ data: Data) throws
    func close()
}

/**
 * One track, once its audio is 16 kHz mono PCM16. It's lined up with the other track by when its
 * first buffer arrived; after its source changes (another microphone, the call audio started again
 * after a stall) the time that took is filled with silence, so the two stay lined up. Buffers arrive
 * on the audio device's thread; everything else is asked from the main one.
 */
public final class TrackWriter: @unchecked Sendable {
    private let output: TrackOutput
    private let lock = NSLock()
    private var samplesWritten = 0
    private var _firstBufferAt: Date?
    private var _lastBufferAt: Date?
    private var gapPending = false
    private var peak: Float = 0
    private var closed = false
    private var _failure: String?

    public init(output: TrackOutput) { self.output = output }

    /// `now` is when the buffer arrived, which is when its last sample was heard.
    public func append(_ samples: UnsafeBufferPointer<Int16>, at now: Date = Date()) {
        let count = samples.count
        var bufferPeak: Int16 = 0
        for v in samples {
            let level = v == Int16.min ? Int16.max : abs(v)
            if level > bufferPeak { bufferPeak = level }
        }
        lock.lock()
        defer { lock.unlock() }
        // A buffer that was already on its way when the recording finished, or after the disk filled.
        guard !closed, _failure == nil else { return }
        do {
            if let first = _firstBufferAt {
                let expected = Int(now.timeIntervalSince(first) * Double(recorderSampleRate)) - count
                if gapPending, expected > samplesWritten {
                    try output.write(Data(count: (expected - samplesWritten) * 2))
                    samplesWritten = expected
                }
            } else {
                _firstBufferAt = now
            }
            gapPending = false
            _lastBufferAt = now
            try output.write(Data(buffer: samples))
            samplesWritten += count
            peak = max(peak, Float(bufferPeak) / Float(Int16.max))
        } catch {
            // Most likely a full disk. The recorder's next look sees this and finishes with what's there.
            _failure = error.localizedDescription
        }
    }

    /// Why this track could no longer be written, once it couldn't.
    public var failure: String? { lock.withLock { _failure } }
    public var firstBufferAt: Date? { lock.withLock { _firstBufferAt } }
    public var lastBufferAt: Date? { lock.withLock { _lastBufferAt } }
    /// Seconds of audio written so far.
    public var elapsed: Double { lock.withLock { Double(samplesWritten) / Double(recorderSampleRate) } }

    /// The source is changing: pad with silence before the next buffer.
    public func markGap() { lock.withLock { gapPending = true } }

    /// Peak level (0–1) since the last call.
    public func takePeak() -> Float {
        lock.withLock {
            defer { peak = 0 }
            return peak
        }
    }

    /// Nothing more is written: a buffer still on its way is dropped.
    public func close() {
        lock.withLock {
            closed = true
            output.close()
        }
    }
}

/// When a capture is started again. The recorder looks once a second at each of its two.
public enum CaptureCheck {
    /// One that isn't running, whose device or format has changed, or that has had no audio for two
    /// seconds is started again. Three seconds are allowed after it starts: some devices, Bluetooth
    /// especially, take a moment to deliver their first audio.
    public static func needsRestart(running: Bool, changed: Bool, startedAt: Date, lastBuffer: Date?, now: Date) -> Bool {
        guard running else { return true }
        let lastSign = max(startedAt.addingTimeInterval(3), lastBuffer ?? .distantPast)
        return changed || now.timeIntervalSince(lastSign) > 2
    }
}

// MARK: - Stopping by itself

/// What the recorder sees in its once-a-second look around.
public struct RecorderSurroundings: Sendable {
    /// The recording's folder is still there: Oatcake makes it, and deletes it to cancel or discard.
    public var folderExists: Bool
    /// Why a track could no longer be written, once one couldn't.
    public var writeFailure: String?
    /// The Oatcake that owns the recording is running. True when there's no saying.
    public var ownerIsRunning: Bool
    /// Bytes free on the recording's disk; nil when that can't be told.
    public var freeSpace: Int64?

    public init(folderExists: Bool, writeFailure: String? = nil, ownerIsRunning: Bool, freeSpace: Int64?) {
        self.folderExists = folderExists
        self.writeFailure = writeFailure
        self.ownerIsRunning = ownerIsRunning
        self.freeSpace = freeSpace
    }
}

/**
 * Whether the recording goes on. It stops by itself when its folder is deleted, when a track can't
 * be written, before the disk is full (so there's still room for meta.json, and for what Oatcake
 * writes next), and when Oatcake has been gone for ten minutes (it may have crashed, to be opened
 * again in a moment; quitting stops the recorder itself).
 */
public struct RecorderWatch: Sendable {
    public enum Verdict: Equatable, Sendable {
        case carryOn
        /// The folder has gone: nothing is left to record into or to finish.
        case abandon
        case finish(Reason)
    }

    /// Why the recording stopped by itself.
    public enum Reason: Equatable, Sendable {
        case cantWrite(String)
        case diskAlmostFull
        case oatcakeGone
    }

    /// A recording stops with this much still free: room for meta.json and for what processing and
    /// saving the call write (its transcript, clips and analysis are small next to the tracks, which
    /// take about 230 MB an hour).
    public static let minimumFreeSpace: Int64 = 100_000_000
    private var ownerGoneSince: Date?

    public init() {}

    public mutating func look(at surroundings: RecorderSurroundings, now: Date = Date()) -> Verdict {
        guard surroundings.folderExists else { return .abandon }
        if let failure = surroundings.writeFailure { return .finish(.cantWrite(failure)) }
        if let free = surroundings.freeSpace, free < Self.minimumFreeSpace { return .finish(.diskAlmostFull) }
        guard !surroundings.ownerIsRunning else {
            ownerGoneSince = nil
            return .carryOn
        }
        let since = ownerGoneSince ?? now
        ownerGoneSince = since
        return now.timeIntervalSince(since) >= recorderOwnerGrace ? .finish(.oatcakeGone) : .carryOn
    }
}

import Foundation
@testable import OatcakeCore
import Testing

/// The recorder's decisions (RecorderContract), without its audio devices.
@Suite struct RecorderTests {
    /// A track's file, in memory.
    private final class Memory: TrackOutput {
        var data = Data()
        var closed = false
        var full = false
        func write(_ more: Data) throws {
            if full { throw CocoaError(.fileWriteOutOfSpace) }
            data.append(more)
        }
        func close() { closed = true }
        var samples: [Int16] { data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
    }

    private func append(_ track: TrackWriter, _ samples: [Int16], at time: Date) {
        samples.withUnsafeBufferPointer { track.append($0, at: time) }
    }

    /// The time a source change took is filled with silence, so the track stays lined up with the
    /// clock (and the other track); without a change, buffers follow one another as they come.
    @Test func trackGapsArePadded() throws {
        let file = Memory()
        let track = TrackWriter(output: file)
        let start = Date(timeIntervalSince1970: 1_000)
        let second = [Int16](repeating: 100, count: 16_000)
        append(track, second, at: start)
        #expect(track.firstBufferAt == start && track.elapsed == 1)
        // A late buffer with no change of source is written straight after: a moment's jitter isn't a gap.
        append(track, [Int16](repeating: 200, count: 1_600), at: start.addingTimeInterval(1.5))
        #expect(file.samples.count == 17_600)

        // The microphone changed (or the call audio stalled and was started again) and five seconds went by.
        track.markGap()
        append(track, [Int16](repeating: 300, count: 1_600), at: start.addingTimeInterval(6))
        // Its first buffer ends six seconds after the first one did: 96,000 samples in, silence before it.
        #expect(file.samples.count == 96_000 && track.elapsed == 6)
        #expect(file.samples[17_600..<94_400].allSatisfy { $0 == 0 } && file.samples[94_400...].allSatisfy { $0 == 300 })
        #expect(track.lastBufferAt == start.addingTimeInterval(6))
        // The gap is filled once.
        append(track, [Int16](repeating: 400, count: 1_600), at: start.addingTimeInterval(9))
        #expect(file.samples.count == 97_600)

        // The loudest sample since the last look, from 0 to 1; Int16.min doesn't overflow.
        append(track, [0, Int16.min, 5], at: start.addingTimeInterval(9.1))
        #expect(track.takePeak() == 1 && track.takePeak() == 0)
    }

    /// A track that can't be written stops taking buffers and says why; one that's closed drops what's still on its way.
    @Test func trackFailsAndCloses() {
        let file = Memory()
        let track = TrackWriter(output: file)
        let now = Date()
        append(track, [1, 2, 3], at: now)
        file.full = true
        append(track, [4, 5, 6], at: now)
        #expect(track.failure != nil && file.samples == [1, 2, 3])
        file.full = false
        append(track, [7], at: now)
        #expect(file.samples == [1, 2, 3])

        let other = Memory()
        let closing = TrackWriter(output: other)
        closing.close()
        append(closing, [1, 2], at: now)
        #expect(other.closed && other.data.isEmpty && closing.failure == nil)
    }

    /// A capture is started again when it isn't running, when its device or format has changed, and
    /// when two seconds go by without audio (three are allowed after it starts).
    @Test func capturesAreRestarted() {
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
        #expect(CaptureCheck.needsRestart(running: false, changed: false, startedAt: start, lastBuffer: nil, now: at(0)))
        #expect(CaptureCheck.needsRestart(running: true, changed: true, startedAt: start, lastBuffer: at(1), now: at(1)))
        // No audio yet: a slow device gets three seconds, and two more.
        #expect(!CaptureCheck.needsRestart(running: true, changed: false, startedAt: start, lastBuffer: nil, now: at(4.5)))
        #expect(CaptureCheck.needsRestart(running: true, changed: false, startedAt: start, lastBuffer: nil, now: at(5.5)))
        // Audio arriving keeps it going; audio that stops for more than two seconds (the lid closed) restarts it.
        #expect(!CaptureCheck.needsRestart(running: true, changed: false, startedAt: start, lastBuffer: at(60), now: at(61.9)))
        #expect(CaptureCheck.needsRestart(running: true, changed: false, startedAt: start, lastBuffer: at(60), now: at(360)))
    }

    /// The recording stops by itself when its folder goes, when a track can't be written, before the
    /// disk is full, and after Oatcake has been gone for ten minutes.
    @Test func recorderStopsByItself() {
        let start = Date(timeIntervalSince1970: 1_000)
        func seen(folder: Bool = true, failure: String? = nil, owner: Bool = true, free: Int64? = 50_000_000_000) -> RecorderSurroundings {
            RecorderSurroundings(folderExists: folder, writeFailure: failure, ownerIsRunning: owner, freeSpace: free)
        }
        var watch = RecorderWatch()
        #expect(watch.look(at: seen(), now: start) == .carryOn)
        // No way of telling the free space isn't a reason to stop.
        #expect(watch.look(at: seen(free: nil), now: start) == .carryOn)
        #expect(watch.look(at: seen(free: RecorderWatch.minimumFreeSpace - 1), now: start) == .finish(.diskAlmostFull))
        #expect(watch.look(at: seen(failure: "The disk is full."), now: start) == .finish(.cantWrite("The disk is full.")))
        // Cancelled or discarded: whatever else is true, there's nothing to finish.
        #expect(watch.look(at: seen(folder: false, failure: "The disk is full.", owner: false), now: start) == .abandon)

        // Oatcake goes: ten minutes' grace, which starts again if it comes back.
        #expect(watch.look(at: seen(owner: false), now: start) == .carryOn)
        #expect(watch.look(at: seen(owner: false), now: start.addingTimeInterval(599)) == .carryOn)
        #expect(watch.look(at: seen(owner: true), now: start.addingTimeInterval(599.5)) == .carryOn)
        #expect(watch.look(at: seen(owner: false), now: start.addingTimeInterval(600)) == .carryOn)
        #expect(watch.look(at: seen(owner: false), now: start.addingTimeInterval(1_199)) == .carryOn)
        #expect(watch.look(at: seen(owner: false), now: start.addingTimeInterval(1_200)) == .finish(.oatcakeGone))
    }
}

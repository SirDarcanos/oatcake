import AVFoundation
import Foundation
import Observation

@MainActor @Observable
public final class RecordingPlayback: NSObject, AVAudioPlayerDelegate {
    public private(set) var duration: TimeInterval = 0
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var isPlaying = false
    public enum Failure: Equatable, Sendable {
        case missingFile, accessDenied, unreadableFile, playbackFailed

        fileprivate init(_ error: any Error) {
            let error = error as NSError
            switch (error.domain, error.code) {
            case (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue),
                 (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue), (NSPOSIXErrorDomain, Int(ENOENT)):
                self = .missingFile
            case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue),
                 (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
                self = .accessDenied
            default:
                self = .unreadableFile
            }
        }
    }

    public private(set) var failure: Failure?
    private var player: AVAudioPlayer?

    public override init() { super.init() }

    public func toggle(_ url: URL) {
        if isPlaying {
            player?.pause()
            refreshPosition()
            isPlaying = false
            return
        }
        guard open(url), let player else { return }
        if elapsed >= duration { seek(to: 0) }
        guard player.play() else { fail(.playbackFailed); return }
        failure = nil
        isPlaying = true
    }

    /// Opens the recording without playing it, so its length is known (and the transcript's times
    /// can be clicked) before Play.
    public func prepare(_ url: URL) {
        guard player == nil, failure == nil else { return }
        _ = open(url)
    }

    /// Checks the file is still there, and loads it if it isn't loaded yet. False, with `failure`
    /// set, when it can't be played.
    private func open(_ url: URL) -> Bool {
        do {
            let file = try FileManager.default.attributesOfItem(atPath: url.path)
            guard file[.type] as? FileAttributeType == .typeRegular else { fail(.unreadableFile); return false }
            if player == nil {
                let audio = try AVAudioPlayer(contentsOf: url)
                guard audio.duration.isFinite, audio.duration > 0 else { fail(.unreadableFile); return false }
                audio.delegate = self
                player = audio
                duration = audio.duration
            }
            return true
        } catch {
            // The file can disappear between checking it and handing it to AVFoundation.
            do {
                _ = try FileManager.default.attributesOfItem(atPath: url.path)
                fail(Failure(error))
            } catch let reachabilityError {
                fail(Failure(reachabilityError))
            }
            return false
        }
    }

    public func seek(to seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        elapsed = min(max(seconds, 0), duration)
        player.currentTime = elapsed
    }

    public func refreshPosition() {
        guard let player else { return }
        elapsed = min(max(player.currentTime, 0), duration)
    }

    public func stop() {
        player?.stop()
        player = nil
        duration = 0
        elapsed = 0
        isPlaying = false
        failure = nil
    }

    private func fail(_ reason: Failure) {
        stop()
        failure = reason
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor in
            guard let player = self.player, ObjectIdentifier(player) == identity else { return }
            if flag {
                self.isPlaying = false
                self.elapsed = self.duration
            } else {
                self.fail(.playbackFailed)
            }
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        let reason = error.map(Failure.init) ?? .unreadableFile
        Task { @MainActor in
            guard let player = self.player, ObjectIdentifier(player) == identity else { return }
            self.fail(reason)
        }
    }
}

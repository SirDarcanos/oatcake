import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct CallTests {
    @Test func callingApps() {
        #expect(CallDetector.callingApp("com.google.Chrome.helper") == "Google Chrome")
        #expect(CallDetector.callingApp("us.zoom.xos") == "Zoom")
        #expect(CallDetector.callingApp("com.apple.WebKit.GPU") == "Safari")
        #expect(CallDetector.callingApp("com.apple.CoreSpeech") == nil)
        #expect(CallDetector.callingApp("local.oatcake.recorder") == nil)
        #expect(CallDetector.callingApp("com.google.Chromecast") == nil)
        // A later edition of an app, and its helpers.
        #expect(CallDetector.callingApp("com.microsoft.teams2") == "Microsoft Teams" && CallDetector.callingApp("com.microsoft.teams2.helper") == "Microsoft Teams")
    }

    /// The live transcript drops a microphone line that only repeats the call audio, and reads in time order.
    @Test func liveLines() {
        let lines = [
            LiveTranscriptLine(track: .mic, start: 12.4, end: 15, text: "I think that's fine, do you agree?"),
            LiveTranscriptLine(track: .system, start: 12, end: 15, text: "I think that's fine, do you agree?"),
            LiveTranscriptLine(track: .mic, start: 16, end: 17, text: "Yes, sounds good to me."),
            LiveTranscriptLine(track: .system, start: 2, end: 4, text: "Morning everyone."),
        ]
        #expect(liveTranscript(lines).map(\.text) == ["Morning everyone.", "I think that's fine, do you agree?", "Yes, sounds good to me."])
        // Each line on the call side gets a made-up name of its own: kept for that line, and never the one before it.
        let names = [4.1, 12.4, 25.0, 33.1, 48.0, 56.2].map { callPlaceholder(for: "a", lineAt: $0) }
        #expect(names.allSatisfy(callPlaceholders.contains))
        #expect(zip(names, names.dropFirst()).allSatisfy { $0 != $1 })
        #expect(callPlaceholder(for: "a", lineAt: 12.4) == names[1])
    }

    /// The live transcript shows speech once it's finished. A sentence still going at the end of the
    /// audio so far waits for the next look, except on the last one, when the recording is over.
    @Test func speechThatHasFinished() {
        let second = sampleRate
        // Two stretches in four seconds of audio; the second runs to within 0.6 s of the end.
        let speaking = [(start: 0.5, end: 1.5), (start: 2.0, end: 3.9)]
        let waiting = finishedSpeech(speaking, samples: 4 * second, last: false)
        // The first is done; the audio is kept from a quarter of a second before the second.
        #expect(waiting.finished == 1 && waiting.consumed == 2 * second - second / 4)
        let over = finishedSpeech(speaking, samples: 4 * second, last: true)
        #expect(over.finished == 2 && over.consumed == 4 * second)
        // Both finished, then quiet: all but the last second is dealt with.
        let quiet = finishedSpeech(speaking, samples: 8 * second, last: false)
        #expect(quiet.finished == 2 && quiet.consumed == 7 * second)
        // Nothing said at all.
        #expect(finishedSpeech([], samples: 5 * second, last: false) == (0, 4 * second))
        // Speech from the very start: nothing before it to keep, so nothing is counted as dealt with.
        #expect(finishedSpeech([(start: 0.1, end: 1.9)], samples: 2 * second, last: false) == (0, 0))
    }
}

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

    /// The silent-microphone notification: once a recording, and once more for each change of microphone.
    @Test func micSilenceIsSaidOnce() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var silence = MicSilence()
        /// One look at the microphone, `seconds` into the recording: whether the notification is due.
        func look(_ device: String?, quiet: Bool, _ seconds: Double) -> Bool {
            silence.look(device: device, quiet: quiet, at: start.addingTimeInterval(seconds))
        }
        func since() -> Double? { silence.since?.timeIntervalSince(start) }

        #expect(!look("headset", quiet: true, 0))
        #expect(!look("headset", quiet: true, 29))
        #expect(look("headset", quiet: true, 30))
        #expect(!look("headset", quiet: true, 31))
        #expect(since() == 0)
        // You speak, then listen for a long while: the live screen says so again, the notification doesn't.
        #expect(!look("headset", quiet: false, 40))
        #expect(since() == nil)
        #expect(!look("headset", quiet: true, 41))
        #expect(!look("headset", quiet: true, 120))
        #expect(since() == 41)
        // Another microphone gets its own half minute and its own notification, and so does going back.
        #expect(!look("built-in", quiet: true, 121))
        #expect(since() == 121)
        #expect(!look("built-in", quiet: true, 150))
        #expect(look("built-in", quiet: true, 151))
        #expect(!look("headset", quiet: true, 152))
        #expect(look("headset", quiet: true, 182))
        // No microphone at all isn't a silent one.
        #expect(!look(nil, quiet: true, 300))
        #expect(since() == nil)

        // A microphone that's never quiet for half a minute at a time says nothing.
        silence = MicSilence()
        for second in stride(from: 0.0, to: 600, by: 20) {
            let said = look("headset", quiet: second.truncatingRemainder(dividingBy: 40) != 0, second)
            #expect(!said)
        }
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

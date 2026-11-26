// The live transcript: while a call is being recorded, a helper process (Oatcake --live <recording
// folder>) reads the audio as the recorder writes it and prints each stretch of speech once it's
// finished, as JSON lines. With Settings › General › Name voices during the call, each line from the
// call side gets a fingerprint, and the name of someone Oatcake knows by voice or you've named on
// another line. Who said what is still worked out properly after the call.

import FluidAudio
import Foundation

/// One line of the live transcript: what was heard on your microphone, or on the call audio.
public struct LiveTranscriptLine: Codable, Equatable, Identifiable, Sendable {
    public enum Track: String, Codable, Sendable { case mic, system }
    public let track: Track
    /// Seconds into the track, which is the time into the call to within a moment.
    public let start: Double
    public var end: Double
    public var text: String
    /// Who said a line from the call side, when it's known: nil until then.
    public var speaker: String?
    /// "mic 12.4". Kept rather than worked out when asked: the live screen asks for every line's
    /// each time it's drawn. Not written out: it follows from the track and start.
    public let id: String

    private enum CodingKeys: String, CodingKey { case track, start, end, text, speaker }

    public init(track: Track, start: Double, end: Double, text: String, speaker: String? = nil) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        id = "\(track.rawValue) \(start)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(track: try c.decode(Track.self, forKey: .track), start: try c.decode(Double.self, forKey: .start),
                  end: try c.decode(Double.self, forKey: .end), text: try c.decode(String.self, forKey: .text),
                  speaker: try c.decodeIfPresent(String.self, forKey: .speaker))
    }
}

/// A new name for a line already shown (nil: nobody now).
public struct LiveSpeaker: Codable, Equatable, Sendable {
    public var line: String
    public var name: String?
}

/// What the live helper is doing before there are any lines to show.
public enum LiveStage: String, Codable, Sendable {
    case downloadingModels, loadingModels, listening

    public var title: String {
        switch self {
        case .downloadingModels: "Downloading the speech models (about 500 MB, first time only)"
        case .loadingModels: "Loading the speech models"
        case .listening: "Listening"
        }
    }
}

/// What the live helper prints: what it's doing, a line, new names for lines already shown, or why it stopped.
public struct LiveEvent: Codable, Equatable, Sendable {
    public var stage: LiveStage?
    public var line: LiveTranscriptLine?
    public var names: [LiveSpeaker]?
    public var error: String?
    public init(stage: LiveStage? = nil, line: LiveTranscriptLine? = nil, names: [LiveSpeaker]? = nil, error: String? = nil) {
        self.stage = stage
        self.line = line
        self.names = names
        self.error = error
    }
}

/// A line of the live transcript you've said who said. They're kept in the recording's
/// live-names.json, where the live transcript follows them during the call and Who's who after it.
public struct LiveName: Codable, Equatable, Sendable {
    /// The line's id (LiveTranscriptLine.id).
    public var line: String
    /// Seconds into the call audio.
    public var start: Double
    public var end: Double
    public var name: String

    public init(line: LiveTranscriptLine, name: String) {
        self.line = line.id
        start = line.start
        end = line.end
        self.name = name
    }
}

/**
 * The name you gave a line of the call side, if you did: the one given to that line or, when the
 * live transcript has started again and cut the call into lines afresh, the one given to the line
 * that covered most of this one (at least half of the shorter of the two).
 */
public func liveName(for line: LiveTranscriptLine, in given: [LiveName]) -> LiveName? {
    if let same = given.last(where: { $0.line == line.id }) { return same }
    func overlap(_ name: LiveName) -> Double { min(name.end, line.end) - max(name.start, line.start) }
    return given
        .filter { line.track == .system && overlap($0) > 0 && overlap($0) >= 0.5 * min($0.end - $0.start, line.end - line.start) }
        .max { overlap($0) < overlap($1) }
}

public enum LiveNames {
    static let file = "live-names.json"

    public static func load(_ dir: URL) -> [LiveName] {
        tryJSON([LiveName].self, dir.appendingPathComponent(file)) ?? []
    }

    public static func save(_ names: [LiveName], in dir: URL) throws {
        try writeAtomic(dir.appendingPathComponent(file), try encodeJSON(names))
    }
}

/// A line from the call side, by its fingerprint: how it scores against each person Oatcake knows by
/// voice is worked out once, as that never changes during the call.
struct LiveVoice {
    var line: String
    var embedding: [Float]
    var known: [String: Float]

    init(line: String, embedding: [Float], known: Voiceprints) {
        self.line = line
        self.embedding = normalise(embedding)
        self.known = known.scores(self.embedding)
    }
}

/**
 * Names the call side's lines, in the order they were said. A line you named is that person's. Any
 * other is whoever it sounds like, by the same rule as review's "Recognised from before" (0.6, and
 * 0.1 ahead of anyone else), against the fingerprints Oatcake has kept and against this call's own
 * lines, averaged for each person named so far. So someone you name once is followed for the rest of
 * the call, and so are earlier lines that sound like them. Naming a line someone else when it sounds
 * like a person Oatcake knows puts that person's kept fingerprints aside for the call: you've said
 * that voice isn't them.
 *
 * One line is a noisy fingerprint next to the average of a whole call, and a line can hold two
 * people, so the names are for following the call: Who's who after it works from whole voices. On a
 * 39-minute AMI meeting (ES2004c), with fingerprints kept from an earlier one, 91% of the speaking
 * time was named right and 1% wrong (a line shared by two people); with nobody known and one line of
 * 4 s or more named for each person, 91% right and none wrong (75% right when the lines named were
 * only 2 s).
 */
func nameLiveVoices(_ voices: [LiveVoice], named: [String: String]) -> [String: String] {
    var sums: [String: [Float]] = [:]
    func add(_ name: String, _ embedding: [Float]) {
        sums[name] = zip(sums[name] ?? [Float](repeating: 0, count: embedding.count), embedding).map(+)
    }
    // What you've said goes from the start of the call: it's who they are.
    var overruled = Set<String>()
    for voice in voices {
        guard let name = named[voice.line] else { continue }
        add(name, voice.embedding)
        overruled.formUnion(voice.known.filter { $0.key != name && $0.value >= matchThreshold }.keys)
    }
    var names: [String: String] = [:]
    for voice in voices {
        if let name = named[voice.line] {
            names[voice.line] = name
            continue
        }
        var scores = voice.known.filter { !overruled.contains($0.key) }
        for (name, sum) in sums { scores[name] = max(scores[name] ?? -1, cosine(voice.embedding, normalise(sum))) }
        guard let match = bestMatch(scores) else { continue }
        names[voice.line] = match.name
        add(match.name, voice.embedding)
    }
    return names
}

/// The lines in the order they were said, without microphone lines that only repeat the call audio
/// (the other side coming out of your speakers).
public func liveTranscript(_ lines: [LiveTranscriptLine]) -> [LiveTranscriptLine] {
    // In order, so each of your lines is held up only against the call lines around it: worked out
    // again for every line that arrives, and a long call has thousands.
    let call = lines.filter { $0.track == .system }.sorted { $0.start < $1.start }.map { Line(speaker: "A", start: $0.start, end: $0.end, text: $0.text) }
    let longest = call.map { $0.end - $0.start }.max() ?? 0
    /// The first call line that starts after `time` (or at it, with `including`).
    func firstStarting(after time: Double, including: Bool = false) -> Int {
        var low = 0, high = call.count
        while low < high {
            let mid = (low + high) / 2
            if call[mid].start < time || (!including && call[mid].start == time) { low = mid + 1 } else { high = mid }
        }
        return low
    }
    return lines
        .filter { line in
            guard line.track == .mic else { return true }
            let near = call[firstStarting(after: line.start - echoWindow - max(0, longest), including: true)..<firstStarting(after: line.end + echoWindow)]
            return !isEcho(Line(speaker: me, start: line.start, end: line.end, text: line.text), Array(near))
        }
        .sorted { $0.start < $1.start }
}

/// Stand-ins for whoever is on the call side of the live transcript: nobody could mistake one for a
/// real name, and the real ones arrive after the call.
public let callPlaceholders = [
    "Mystery Guest", "Speaker McSpeakerface", "Name Pending", "Voice To Be Named", "Captain Placeholder", "The Other End",
    "Somebody Important", "Guest Star", "To Be Announced", "Whoever That Is", "Unnamed Legend", "A Voice On The Call",
]

/**
 * A stand-in for whoever said one line on the call side. Every line gets its own, picked at random
 * the first time the line is shown and kept for it from then on, and never the one the line before
 * got, so each turn reads as someone new until the real names arrive. Only the call being recorded
 * is remembered.
 */
public func callPlaceholder(for recording: String, lineAt start: Double) -> String {
    placeholderLock.withLock {
        if chosenFor != recording {
            chosenFor = recording
            chosenPlaceholders = [:]
            lastPlaceholder = nil
        }
        let line = Int((start * 10).rounded())
        if let chosen = chosenPlaceholders[line] { return chosen }
        let chosen = callPlaceholders.filter { $0 != lastPlaceholder }.randomElement()!
        chosenPlaceholders[line] = chosen
        lastPlaceholder = chosen
        return chosen
    }
}
// These three are only read and written inside `placeholderLock`.
private let placeholderLock = NSLock()
nonisolated(unsafe) private var chosenFor = ""
nonisolated(unsafe) private var chosenPlaceholders: [Int: String] = [:]
nonisolated(unsafe) private var lastPlaceholder: String?

/**
 * Transcribes a recording while it's being made, reporting each line as it's finished. Returns once
 * the recorder has finished (meta.json is there), the recording has been thrown away, or Oatcake
 * itself has gone.
 */
public func transcribeLive(_ dir: URL, config: Config = Config.load(), voiceprints: URL = Paths.voiceprints,
                           report: @escaping (LiveEvent) -> Void) async throws {
    report(LiveEvent(stage: SpeechModels.needsDownload(config.asrModel) ? .downloadingModels : .loadingModels))
    let transcriber = try await SpeechModels.loadTranscriber(config.asrModel)
    // The voice models (about 180 MB of memory) only when voices are named. If they won't load, the
    // transcript goes on without names.
    var fingerprints: OfflineDiarizerManager?
    if config.liveVoices { fingerprints = try? await SpeechModels.loadDiarizer(live: true) }
    let known = Voiceprints.load(voiceprints)
    var voices: [LiveVoice] = []
    var calls: [LiveTranscriptLine] = []
    var given: [LiveName] = []
    var shown: [String: String] = [:]
    report(LiveEvent(stage: .listening))
    // Samples of each track already dealt with. The call audio first, so a line of yours that only
    // echoes it is recognised as an echo straight away.
    var done: [(track: LiveTranscriptLine.Track, file: String, samples: Int)] = [(.system, "system.pcm", 0), (.mic, "mic.pcm", 0)]
    let oatcake = getppid()
    while true {
        guard FileManager.default.exists(dir), getppid() == oatcake else { return }
        let finished = FileManager.default.exists(dir.appendingPathComponent("meta.json"))
        var lines: [LiveTranscriptLine] = []
        for i in done.indices {
            let fresh = readPcm(dir.appendingPathComponent(done[i].file), fromSample: done[i].samples)
            guard fresh.count >= sampleRate / 2 else { continue }
            // Once the recorder has finished, what's left is all there will be: its last words included.
            let (utterances, consumed) = try await transcriber.transcribeFinished(fresh, last: finished)
            let offset = Double(done[i].samples) / Double(sampleRate)
            let new = utterances.map { LiveTranscriptLine(track: done[i].track, start: $0.start + offset, end: $0.end + offset, text: $0.text) }
            if let fingerprints, done[i].track == .system, !utterances.isEmpty,
               let prints = try? await fingerprints.embedSpans(audioSource: ArrayAudioSampleSource(samples: fresh), spans: utterances.map { $0.start..<$0.end }),
               prints.count == new.count {
                voices += zip(new, prints).map { LiveVoice(line: $0.id, embedding: $1, known: known) }
            }
            lines += new
            done[i].samples += consumed
        }
        // Names follow your choices even without fingerprints (the voice models wouldn't load, or a
        // line couldn't be fingerprinted): a name you give or take back is shown on its line either way.
        if config.liveVoices {
            let now = LiveNames.load(dir)
            calls += lines.filter { $0.track == .system }
            if !lines.isEmpty || now != given {
                given = now
                var named: [String: String] = [:]
                for line in calls { if let name = liveName(for: line, in: given) { named[line.id] = name.name } }
                var names = nameLiveVoices(voices, named: named)
                names.merge(named) { _, yours in yours }
                let new = Set(lines.map(\.id))
                let changed = calls.map(\.id).filter { !new.contains($0) && names[$0] != shown[$0] }
                if !changed.isEmpty { report(LiveEvent(names: changed.map { LiveSpeaker(line: $0, name: names[$0]) })) }
                for i in lines.indices { lines[i].speaker = names[lines[i].id] }
                shown = names
            }
        }
        for line in lines { report(LiveEvent(line: line)) }
        if finished { return }
        try await Task.sleep(for: .seconds(1.5))
    }
}

/**
 * When to say that the microphone has gone silent during a call. `since` is when it went quiet, for
 * the live screen, which says so for as long as it lasts. The notification is another matter: a
 * headset that cuts out room noise, or a quiet mic, is silent whenever you aren't talking, so one
 * for every quiet spell would go on all through a call you're listening to. It's given once a
 * recording, and once more after each change of microphone, which starts its half minute again.
 */
public struct MicSilence: Sendable {
    /// When the microphone in use went quiet, while it is.
    public private(set) var since: Date?
    private var device: String?
    private var said = false

    public init() {}

    /// The latest look: the microphone in use (nil for none) and whether nothing is arriving from
    /// it. True when the notification is due now.
    public mutating func look(device: String?, quiet: Bool, at now: Date) -> Bool {
        if device != self.device {
            self.device = device
            since = nil
            said = false
        }
        since = device != nil && quiet ? since ?? now : nil
        guard let since, now.timeIntervalSince(since) >= 30, !said else { return false }
        said = true
        return true
    }
}

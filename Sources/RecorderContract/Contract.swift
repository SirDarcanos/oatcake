// What Oatcake and its recorder agree on. The recorder is a separate program that Oatcake only ever
// talks to through files in the recording's folder (and one question on a socket as it starts), so
// the names of those files and the shape of what's in them live here, used by both.

import Foundation

/// Both tracks are 16 kHz mono PCM16. (Earlier meta.json files say so in a sampleRate of their own,
/// which nothing reads.)
public let recorderSampleRate = 16_000

/// The files in a recording's folder that the two programs share.
public enum RecorderFile {
    /// Written by the recorder once a second while it records.
    public static let status = "status.json"
    /// Written by the recorder as it finishes.
    public static let meta = "meta.json"
    /// Written by Oatcake: the microphone to record. Re-read once a second.
    public static let mic = "mic.json"
    /// The recorder's process ID, while it runs.
    public static let pid = "recorder.pid"
    /// Oatcake's process ID. When that process has been gone for a while the recorder stops by itself.
    public static let owner = "owner.pid"
    public static let micTrack = "mic.pcm"
    public static let systemTrack = "system.pcm"
}

/// How long the recorder carries on with no Oatcake running (it may have crashed, to be opened
/// again in a moment) before it finishes the recording by itself.
public let recorderOwnerGrace: TimeInterval = 600

public struct MicChoice: Codable, Equatable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// mic.json: the input Oatcake asks for; nil follows the Mac's own input.
public struct MicRequest: Codable, Equatable, Sendable {
    public var uid: String?
    public init(uid: String?) { self.uid = uid }

    // null, rather than no key at all: a file that says "the Mac's input" reads differently from one cut short.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let uid { try c.encode(uid, forKey: .uid) } else { try c.encodeNil(forKey: .uid) }
    }
}

public struct RecorderStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case starting, recording, stopped, error }
    public var state: State
    /// Why it stopped, in words for the person recording.
    public var error: String?
    /// Seconds since recording started.
    public var elapsed: Double?
    /// Peak levels (0 to 1) since the last status.
    public var micLevel: Double?
    public var systemLevel: Double?
    /// The input being recorded right now; nil when there's none.
    public var micDevice: MicChoice?
    /// While starting: macOS is asking whether Oatcake may use the microphone or record system audio,
    /// and the recorder waits for the answer.
    public var waitingForPermission: Bool?
    /// Seconds from the start to each track's first sample, once it has one: what meta.json will say,
    /// kept here as well for a recorder that goes without finishing.
    public var micOffset: Double?
    public var systemOffset: Double?

    public init(state: State, error: String? = nil, elapsed: Double? = nil, micLevel: Double? = nil, systemLevel: Double? = nil, micDevice: MicChoice? = nil,
                waitingForPermission: Bool? = nil, micOffset: Double? = nil, systemOffset: Double? = nil) {
        self.state = state
        self.error = error
        self.elapsed = elapsed
        self.micLevel = micLevel
        self.systemLevel = systemLevel
        self.micDevice = micDevice
        self.waitingForPermission = waitingForPermission
        self.micOffset = micOffset
        self.systemOffset = systemOffset
    }
}

/// meta.json: what the recorder knows about the recording once it's over.
public struct RecorderMeta: Codable, Equatable, Sendable {
    /// ISO 8601.
    public var startedAt: String
    public var endedAt: String
    /// Seconds from startedAt to each track's first sample, for lining the two up.
    public var micOffset: Double
    public var systemOffset: Double
    /// Written by Oatcake, not the recorder: the recorder went without finishing and without saying
    /// where a track that has audio starts, so the offsets are a guess.
    public var interrupted: Bool?

    public init(startedAt: String, endedAt: String, micOffset: Double, systemOffset: Double, interrupted: Bool? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.micOffset = micOffset
        self.systemOffset = systemOffset
        self.interrupted = interrupted
    }
}

/**
 * The recorder is what uses the microphone and system-audio permissions (macOS gives them to
 * Oatcake, which it is inside), so it only records when Oatcake itself asked it to. As it starts it connects to the socket it was given, checks that the program
 * at the other end really is Oatcake (by its code signature, not by anything it says), and asks
 * whether Oatcake wants a recording in this folder. Anything else that launches the recorder gets
 * nothing: it can't pass that check, and Oatcake only says yes to recordings it started.
 */
public enum RecorderGate {
    /// `--ask <socket path>`: where the recorder puts its question.
    public static let argument = "--ask"
    public static let yes = "yes"
    public static let no = "no"
    static let recorderIdentifier = "identifier \"local.oatcake.recorder\""
    static let appIdentifier = "identifier \"local.oatcake\""
    /// The first Oatcake signed for the hardened runtime. Earlier releases carry the same certificate
    /// but let another program load its code into them, so one of those answering for Oatcake
    /// proves nothing: the recorder doesn't take its word. (The recorder also checks the hardened
    /// runtime itself; the version is the part a code-signing requirement can state.)
    public static let firstTrustedVersion = "0.5.0"

    public enum Caller: Equatable, Sendable {
        /// A development build, signed ad-hoc: it has no permissions worth guarding and nothing to check against.
        case anyone
        /// The code-signing requirement the program that asks must meet: Oatcake, of a version that can
        /// be trusted to be only itself, signed the way the recorder is.
        case mustMeet(String)
        /// A signature this version doesn't know how to read. Nothing is recorded.
        case nobody
    }

    /// Who may ask this recorder to record, from the recorder's own designated requirement
    /// (`identifier "local.oatcake.recorder" and certificate leaf = H"…"` for a release). Whatever
    /// follows the recorder's identifier says who signed it, and Oatcake has to be signed the same.
    public static func caller(forRecorder designated: String) -> Caller {
        let requirement = designated.trimmingCharacters(in: .whitespacesAndNewlines)
        if requirement.hasPrefix("cdhash") { return .anyone }
        guard requirement.hasPrefix(recorderIdentifier + " and ") else { return .nobody }
        return .mustMeet("\(appIdentifier) and info [CFBundleShortVersionString] >= \"\(firstTrustedVersion)\"" + requirement.dropFirst(recorderIdentifier.count))
    }
}

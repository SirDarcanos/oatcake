// One call's working folder in Paths.recordings: call.json, the recorder's audio and status,
// meta.json, notes.json, analysis.json, clips/, saved.json. It's there until the call has been saved
// as a meeting; then it goes (tidySaved), since everything the meeting needs is in its own folder.

import Foundation
// The recorder's status, its meta.json and the microphone choice are shared with the recorder itself.
@_exported import RecorderContract

public struct Recording: Codable, Identifiable, Equatable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case recording, recorded, processed, saved }
    public var id: String
    public var dir: URL
    public var title: String
    /// Meetings folder (relative path) picked when the recording started; "" is the top level.
    public var folder: String?
    /// The calendar event it was started from, if any, and who else was invited to it.
    public var eventId: String?
    public var attendees: [String]?
    public var startedAt: Date
    /// When recording stopped (from the recorder's meta.json).
    public var endedAt: Date?
    public var state: State
}

public struct InputDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var uid: String
    public var name: String
    public var isDefault: Bool
    public var id: String { uid }
}

public struct Note: Codable, Equatable, Sendable {
    /// Seconds into the recording when the line was started; nil for a prep note written beforehand.
    public var at: Double?
    public var text: String
    public init(at: Double?, text: String) {
        self.at = at
        self.text = text
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let at { try c.encode(at, forKey: .at) } else { try c.encodeNil(forKey: .at) }
        try c.encode(text, forKey: .text)
    }
}

/// What call.json holds.
struct CallInfo: Codable {
    var title: String
    var folder: String?
    var startedAt: String
    var eventId: String?
    var attendees: [String]?
}

public enum Recordings {
    /// Answers the recorder when it asks whether Oatcake wants a recording (RecorderDoor).
    static let door = RecorderDoor()

    /// The recorder app: inside Oatcake.app, or beside the binary in a development build.
    public static var recorderApp: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/OatcakeRecorder.app")
        if FileManager.default.exists(bundled) { return bundled }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("OatcakeRecorder.app")
    }

    static var recorderBinary: URL { recorderApp.appendingPathComponent("Contents/MacOS/oatcake-recorder") }

    /// The Mac's input devices, read by the recorder (listing them needs no permission).
    public static func listInputs() async throws -> [InputDevice] {
        let binary = recorderBinary.path
        return try await Task.detached {
            try JSONDecoder().decode([InputDevice].self, from: Data(runCapturing(binary, ["--list-inputs"]).utf8))
        }.value
    }

    /// The recorder re-reads mic.json every second, so this switches input mid-call.
    public static func setMic(_ dir: URL, uid: String?) throws {
        try writeAtomic(dir.appendingPathComponent(RecorderFile.mic), try JSONEncoder().encode(MicRequest(uid: uid)))
    }

    public struct StartOptions: Sendable {
        /// The calendar event this call was started from.
        public var eventId: String?
        /// Prep notes written before the call; they open the call's notes.
        public var prep: [String] = []
        /// The other people on the event's invite: offered as names in Who's who.
        public var attendees: [String] = []
        public init(eventId: String? = nil, prep: [String] = [], attendees: [String] = []) {
            self.eventId = eventId
            self.prep = prep
            self.attendees = attendees
        }
    }

    public static func start(title: String, folder: String, micUid: String?, options: StartOptions = StartOptions()) throws -> Recording {
        guard FileManager.default.exists(recorderApp) else {
            throw OatcakeError("The recorder isn't built. Run Scripts/bundle.sh.")
        }
        let startedAt = Date()
        let id = isoString(startedAt).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        let dir = Paths.recordings.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeAtomic(dir.appendingPathComponent("call.json"),
                        try encodeJSON(CallInfo(title: title, folder: folder, startedAt: isoString(startedAt), eventId: options.eventId,
                                                attendees: options.attendees.isEmpty ? nil : options.attendees)))
        let prep = options.prep.map(\.trimmed).filter { !$0.isEmpty }
        if !prep.isEmpty { try saveNotes(id, prep.map { Note(at: nil, text: $0) }) }
        try setMic(dir, uid: micUid)
        try writeAtomic(dir.appendingPathComponent(RecorderFile.owner), String(getpid()))
        // The recorder only records for Oatcake: it asks at this socket whether this folder's recording is wanted.
        let socket = try door.expect(dir)
        // Launched through LaunchServices so macOS treats the recorder as its own app for permissions.
        do {
            try runCapturing("/usr/bin/open", ["-n", "-g", recorderApp.path, "--args", "--out", dir.path, RecorderGate.argument, socket])
        } catch {
            door.forget(dir)
            throw error
        }
        return Recording(id: id, dir: dir, title: title, folder: folder, eventId: options.eventId,
                         attendees: options.attendees.isEmpty ? nil : options.attendees, startedAt: startedAt, state: .recording)
    }

    public static func status(_ rec: Recording) -> RecorderStatus {
        // Missing, or caught mid-write.
        tryJSON(RecorderStatus.self, rec.dir.appendingPathComponent(RecorderFile.status)) ?? RecorderStatus(state: .starting)
    }

    /// Says that this copy of Oatcake is looking after a recording (a new one, or one picked up again
    /// at launch). The recorder stops by itself once the process named here has been gone ten minutes.
    public static func adopt(_ rec: Recording) {
        try? writeAtomic(rec.dir.appendingPathComponent(RecorderFile.owner), String(getpid()))
    }

    /// The recorder's process ID, while that process is still running and is our recorder.
    static func recorderPid(_ rec: Recording) -> pid_t? {
        guard let text = try? String(contentsOf: rec.dir.appendingPathComponent(RecorderFile.pid), encoding: .utf8),
              let pid = pid_t(text.trimmed), pid > 1 else { return nil }
        // A crashed recorder leaves its pid file behind, and macOS reuses process IDs.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasSuffix("/oatcake-recorder") else { return nil }
        return pid
    }

    public static func isRunning(_ rec: Recording) -> Bool { recorderPid(rec) != nil }

    /// Asks the recorder to finish (it writes meta.json as it exits). Does nothing if it already stopped.
    public static func stop(_ rec: Recording) {
        if let pid = recorderPid(rec) { Darwin.kill(pid, SIGTERM) }
    }

    /// Stops a recorder that didn't finish when asked. It writes no meta.json then: finishInterrupted makes one.
    public static func kill(_ rec: Recording) {
        if let pid = recorderPid(rec) { Darwin.kill(pid, SIGKILL) }
    }

    /// Whether the recorder captured anything at all.
    public static func hasAudio(_ rec: Recording) -> Bool { audioTracks.contains { size(rec.dir.appendingPathComponent($0)) > 0 } }

    private static let audioTracks = ["mic.pcm", "system.pcm"]

    private static func size(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64) ?? 0
    }

    /**
     * A recording whose recorder stopped without writing meta.json: it crashed, was killed, or never got
     * past the permission prompt. Writes a meta.json from what's on disk, so the audio it did capture is
     * processed like any other recording (and can be discarded from Needs review if there's nothing).
     */
    public static func finishInterrupted(_ rec: Recording) {
        let fm = FileManager.default
        guard !fm.exists(rec.dir.appendingPathComponent("meta.json")), !isRunning(rec) else { return }
        let modified = ["mic.pcm", "system.pcm", "status.json"]
            .compactMap { (try? fm.attributesOfItem(atPath: rec.dir.appendingPathComponent($0).path))?[.modificationDate] as? Date }
            .max() ?? rec.startedAt
        // The tracks are taken as starting together: their offsets are unknown.
        let meta = RecorderMeta(startedAt: isoString(rec.startedAt), endedAt: isoString(modified),
                                micOffset: 0, systemOffset: 0, interrupted: true)
        if let text = try? encodeJSON(meta) { try? writeAtomic(rec.dir.appendingPathComponent("meta.json"), text) }
        try? fm.removeItem(at: rec.dir.appendingPathComponent("recorder.pid"))
    }

    public static func list() -> [Recording] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: Paths.recordings.path) else { return [] }
        return ids.sorted().reversed().compactMap { id -> Recording? in
            let dir = Paths.recordings.appendingPathComponent(id, isDirectory: true)
            // One damaged file shouldn't hide every other recording.
            guard let call = tryJSON(CallInfo.self, dir.appendingPathComponent("call.json")) else { return nil }
            let has = { fm.exists(dir.appendingPathComponent($0)) }
            let state: Recording.State = has("saved.json") ? .saved : has("analysis.json") ? .processed : has("meta.json") ? .recorded : .recording
            let endedAt = tryJSON(RecorderMeta.self, dir.appendingPathComponent("meta.json")).flatMap { parseISO($0.endedAt) }
            return Recording(id: id, dir: dir, title: call.title, folder: call.folder, eventId: call.eventId, attendees: call.attendees,
                             startedAt: parseISO(call.startedAt) ?? Date(), endedAt: endedAt, state: state)
        }
    }

    public static func get(_ id: String) -> Recording? { list().first { $0.id == id } }

    /// Recording IDs are their start time, e.g. 2026-11-05T22-35-10-123Z. Anything else is refused.
    static func dir(_ id: String) throws -> URL {
        guard id.range(of: #"^\d{4}-\d\d-\d\dT[\dZ-]+$"#, options: .regularExpression) != nil else { throw OatcakeError("Recording not found") }
        return Paths.recordings.appendingPathComponent(id, isDirectory: true)
    }

    public static func saveNotes(_ id: String, _ notes: [Note]) throws {
        try writeAtomic(try dir(id).appendingPathComponent("notes.json"), try encodeJSON(notes))
    }

    public static func loadNotes(_ id: String) -> [Note] {
        (try? dir(id)).flatMap { tryJSON([Note].self, $0.appendingPathComponent("notes.json")) } ?? []
    }

    public static func discard(_ id: String) throws {
        try FileManager.default.removeItem(at: try dir(id))
    }

    static func deleteAudio(_ rec: Recording) {
        for name in audioTracks + ["clips"] { try? FileManager.default.removeItem(at: rec.dir.appendingPathComponent(name)) }
    }

    /**
     * Clears away the working folders of recordings that have been saved as meetings. One whose audio
     * was kept (Keep call audio) first has it written into its meeting's folder as audio.m4a, so it's
     * with the meeting and goes to the Trash with it; if that meeting can't be found, the folder is
     * left as it is. Slow for kept audio, so it's run in the background: at launch and after each save.
     */
    public static func tidySaved(meetingsRoot: URL, recordings: URL = Paths.recordings) {
        let fm = FileManager.default
        for id in (try? fm.contentsOfDirectory(atPath: recordings.path)) ?? [] {
            let dir = recordings.appendingPathComponent(id, isDirectory: true)
            guard let saved = tryJSON([String: String].self, dir.appendingPathComponent("saved.json")) else { continue }
            if audioTracks.contains(where: { size(dir.appendingPathComponent($0)) > 0 }) {
                guard let meeting = savedMeeting(id, saved["meeting"], under: meetingsRoot) else { continue }
                let audio = meeting.appendingPathComponent("audio.m4a")
                if !fm.exists(audio), (try? exportAudio(recording: dir, to: audio)) == nil { continue }
            }
            try? fm.removeItem(at: dir)
        }
    }

    /// The meeting folder a saved recording went to: where saved.json says, or wherever it has been
    /// moved or renamed to since (its meeting.json names the recording).
    private static func savedMeeting(_ id: String, _ rel: String?, under root: URL) -> URL? {
        func isIt(_ dir: URL) -> Bool {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")) else { return false }
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["recording"] as? String == id
        }
        if let rel, let dir = try? resolveInside(root, rel), isIt(dir) { return dir }
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == "meeting.json", isIt(url.deletingLastPathComponent()) { return url.deletingLastPathComponent() }
        }
        return nil
    }
}

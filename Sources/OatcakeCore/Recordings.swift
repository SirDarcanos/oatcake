// One call's working folder in the recordings folder (Paths.recordings, or wherever a test says): call.json, the recorder's audio and status,
// meta.json, notes.json, analysis.json, clips/, saved.json. It's there until the call has been saved
// as a meeting; then it goes (tidySaved), since everything the meeting needs is in its own folder. A
// meeting saved without checking who's who keeps its analysis and clips until the voices are named.

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
    public var summaryTemplate: String?
    /// The calendar event it was started from, if any, and who else was invited to it.
    public var eventId: String?
    public var attendees: [String]?
    public var calendarIDs: [UUID]?
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

/// What saved.json holds: where the recording was saved and, while who's who hasn't been checked, the
/// name each voice was saved under (so naming them later knows what to replace).
public struct SavedInfo: Codable, Equatable, Sendable {
    public var meeting: String?
    public var unchecked: Bool?
    public var names: [String: String]?
    public init(meeting: String?, unchecked: Bool? = nil, names: [String: String]? = nil) {
        self.meeting = meeting
        self.unchecked = unchecked
        self.names = names
    }
    public var isUnchecked: Bool { unchecked == true }
}

/// What call.json holds.
struct CallInfo: Codable {
    var title: String
    var folder: String?
    var startedAt: String
    var eventId: String?
    var attendees: [String]?
    var calendarIDs: [UUID]?
    var summaryTemplate: String?
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

    /**
     * macOS gives the microphone and system-audio permissions to Oatcake itself (the recorder is
     * inside it), and remembers them against Oatcake's code-signing requirement as it was when you
     * allowed them. Before 0.5.0 that was "this identifier, this certificate", which every earlier
     * release meets, and their recorders record for whoever starts them. From 0.5.0 the requirement
     * also says "0.5.0 or later" (Scripts/bundle.sh). So the permissions are withdrawn once, and
     * macOS asks again at the next recording: given to this version, they no longer cover an
     * earlier copy of Oatcake that something else has started. False when macOS wouldn't.
     *
     * The recorder's own identifier is done too, in case a version of macOS remembers them against
     * that, but it doesn't count towards the answer: macOS refuses an identifier it has never seen
     * launched, as a new install's recorder is, and trying again later would take away permissions
     * that had been given since.
     */
    public static func withdrawEarlierPermissions(of bundleID: String) -> Bool {
        func withdraw(_ id: String) -> Bool {
            ["Microphone", "AudioCapture"].map { (try? runCapturing("/usr/bin/tccutil", ["reset", $0, id])) != nil }.allSatisfy { $0 }
        }
        _ = withdraw(bundleID + ".recorder")
        return withdraw(bundleID)
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
        public var summaryTemplate: String?
        public var calendarIDs: [UUID]
        public init(eventId: String? = nil, prep: [String] = [], attendees: [String] = [], summaryTemplate: String? = nil,
                    calendarIDs: [UUID] = []) {
            self.eventId = eventId
            self.prep = prep
            self.attendees = attendees
            self.summaryTemplate = summaryTemplate
            self.calendarIDs = calendarIDs
        }
    }

    /// Makes a recording's folder and gets ready for its recorder, which `launchRecorder` then starts.
    /// Returns the recording and the socket its recorder is to ask at.
    public static func start(title: String, folder: String, micUid: String?, options: StartOptions = StartOptions(),
                             recordings: URL = Paths.recordings) throws -> (recording: Recording, socket: String) {
        guard FileManager.default.exists(recorderApp) else {
            throw OatcakeError("The recorder isn't built. Run Scripts/bundle.sh.")
        }
        let startedAt = Date()
        let id = isoString(startedAt).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        let dir = recordings.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A folder left half-made would come back at the next launch as an empty recording to review.
        do {
            let calendarIDs = options.calendarIDs.isEmpty ? nil : options.calendarIDs
            try writeAtomic(dir.appendingPathComponent("call.json"),
                            try encodeJSON(CallInfo(title: title, folder: folder, startedAt: isoString(startedAt), eventId: options.eventId,
                                                    attendees: options.attendees.isEmpty ? nil : options.attendees,
                                                    calendarIDs: calendarIDs, summaryTemplate: options.summaryTemplate)))
            let prep = options.prep.map(\.trimmed).filter { !$0.isEmpty }
            if !prep.isEmpty { try saveNotes(id, prep.map { Note(at: nil, text: $0) }, recordings: recordings) }
            try setMic(dir, uid: micUid)
            try writeAtomic(dir.appendingPathComponent(RecorderFile.owner), String(getpid()))
            // The recorder only records for Oatcake: it asks at this socket whether this folder's recording is wanted.
            let socket = try door.expect(dir)
            let rec = Recording(id: id, dir: dir, title: title, folder: folder, summaryTemplate: options.summaryTemplate, eventId: options.eventId,
                                attendees: options.attendees.isEmpty ? nil : options.attendees, calendarIDs: calendarIDs,
                                startedAt: startedAt, state: .recording)
            return (rec, socket)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /**
     * Starts a recording's recorder, through LaunchServices, so it runs as an app of its own and not
     * as Oatcake's child (macOS still counts the microphone and system audio it uses as Oatcake's).
     * `open` can take a while, the first time especially, so it's waited for off the caller's thread.
     */
    public static func launchRecorder(_ rec: Recording, socket: String) async throws {
        let app = recorderApp.path
        do {
            _ = try await Task.detached {
                try runCapturing("/usr/bin/open", ["-n", "-g", app, "--args", "--out", rec.dir.path, RecorderGate.argument, socket])
            }.value
        } catch {
            door.forget(rec.dir)
            throw error
        }
    }

    public static func status(_ rec: Recording) -> RecorderStatus {
        // Missing, or caught mid-write.
        tryJSON(RecorderStatus.self, rec.dir.appendingPathComponent(RecorderFile.status)) ?? RecorderStatus(state: .starting)
    }

    /// The recording is being stopped or thrown away before its recorder got going: a recorder that
    /// asks about it from now on is told no, and goes away.
    public static func cancelStart(_ rec: Recording) {
        door.forget(rec.dir)
    }

    /// Says that this copy of Oatcake is looking after a recording (a new one, or one picked up again
    /// at launch). The recorder stops by itself once the process named here has been gone ten minutes.
    public static func adopt(_ rec: Recording) {
        try? writeAtomic(rec.dir.appendingPathComponent(RecorderFile.owner), String(getpid()))
    }

    /// The recorder's process ID, while that process is still running and is our recorder.
    static func recorderPid(_ rec: Recording) -> pid_t? {
        runningPid(in: rec.dir.appendingPathComponent(RecorderFile.pid), program: ProgramName.recorder)
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

    /// Seconds of audio in the longer of the two tracks.
    public static func audioSeconds(_ rec: Recording) -> Double {
        Double(audioTracks.map { size(rec.dir.appendingPathComponent($0)) }.max() ?? 0) / 2 / Double(sampleRate)
    }

    private static let audioTracks = [RecorderFile.micTrack, RecorderFile.systemTrack]

    private static func size(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64) ?? 0
    }

    /**
     * A recording whose recorder stopped without writing meta.json: it crashed, was killed, or never got
     * past the permission prompt. Writes a meta.json from what's on disk, so the audio it did capture is
     * processed like any other recording (and can be discarded from Needs review if there's nothing).
     * Where each track starts is in the recorder's last status; a track with audio that it doesn't
     * give one for is taken as starting with the recording, a guess Who's who mentions.
     */
    public static func finishInterrupted(_ rec: Recording) {
        let fm = FileManager.default
        guard !fm.exists(rec.dir.appendingPathComponent(RecorderFile.meta)), !isRunning(rec) else { return }
        let modified = (audioTracks + [RecorderFile.status])
            .compactMap { (try? fm.attributesOfItem(atPath: rec.dir.appendingPathComponent($0).path))?[.modificationDate] as? Date }
            .max() ?? rec.startedAt
        let status = tryJSON(RecorderStatus.self, rec.dir.appendingPathComponent(RecorderFile.status))
        let mic = status?.micOffset, system = status?.systemOffset
        let guessed = (mic == nil && size(rec.dir.appendingPathComponent(RecorderFile.micTrack)) > 0)
            || (system == nil && size(rec.dir.appendingPathComponent(RecorderFile.systemTrack)) > 0)
        let meta = RecorderMeta(startedAt: isoString(rec.startedAt), endedAt: isoString(modified),
                                micOffset: mic ?? 0, systemOffset: system ?? 0, interrupted: guessed ? true : nil)
        if let text = try? encodeJSON(meta) { try? writeAtomic(rec.dir.appendingPathComponent(RecorderFile.meta), text) }
        try? fm.removeItem(at: rec.dir.appendingPathComponent(RecorderFile.pid))
    }

    /**
     * The recordings waiting to be processed or reviewed: recorded and processed ones, and one still
     * "recording" whose recorder has gone (no meta.json, no recorder running, not one of `live`).
     * That's a recorder that couldn't write meta.json and Oatcake couldn't either (the disk was full),
     * which would otherwise stay out of sight until Oatcake was reopened.
     */
    public static func waiting(except live: Set<String>, recordings: URL = Paths.recordings) -> [Recording] {
        list(recordings: recordings).compactMap { rec in
            var rec = rec
            switch rec.state {
            case .recorded, .processed: return rec
            case .recording where !live.contains(rec.id) && !isRunning(rec):
                rec.state = .recorded
                return rec
            default: return nil
            }
        }
    }

    /// The analysis helper writes this beside analysis.json, and Oatcake takes it away once it has done
    /// its own part (suggesting names, then saving the call by itself if Settings says to). One still
    /// there at launch was cut short by a quit, and that part is done again.
    static let lastStepFile = "last-step"

    public static func lastStepPending(_ rec: Recording) -> Bool { FileManager.default.exists(rec.dir.appendingPathComponent(lastStepFile)) }

    public static func lastStepDone(_ rec: Recording) { try? FileManager.default.removeItem(at: rec.dir.appendingPathComponent(lastStepFile)) }

    public static func list(recordings: URL = Paths.recordings) -> [Recording] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: recordings.path) else { return [] }
        return ids.sorted().reversed().compactMap { id -> Recording? in
            let dir = recordings.appendingPathComponent(id, isDirectory: true)
            // One damaged file shouldn't hide every other recording.
            guard let call = tryJSON(CallInfo.self, dir.appendingPathComponent("call.json")) else { return nil }
            let has = { fm.exists(dir.appendingPathComponent($0)) }
            let state: Recording.State = has("saved.json") ? .saved : has("analysis.json") ? .processed : has(RecorderFile.meta) ? .recorded : .recording
            let endedAt = tryJSON(RecorderMeta.self, dir.appendingPathComponent(RecorderFile.meta)).flatMap { parseISO($0.endedAt) }
            return Recording(id: id, dir: dir, title: call.title, folder: call.folder, summaryTemplate: call.summaryTemplate,
                             eventId: call.eventId, attendees: call.attendees, calendarIDs: call.calendarIDs,
                             startedAt: parseISO(call.startedAt) ?? Date(), endedAt: endedAt, state: state)
        }
    }

    public static func get(_ id: String, recordings: URL = Paths.recordings) -> Recording? { list(recordings: recordings).first { $0.id == id } }

    /// Recording IDs are their start time, e.g. 2026-11-05T22-35-10-123Z. Anything else is refused.
    static func dir(_ id: String, recordings: URL = Paths.recordings) throws -> URL {
        guard id.range(of: #"^\d{4}-\d\d-\d\dT[\dZ-]+$"#, options: .regularExpression) != nil else { throw OatcakeError("Recording not found") }
        return recordings.appendingPathComponent(id, isDirectory: true)
    }

    public static func saveNotes(_ id: String, _ notes: [Note], recordings: URL = Paths.recordings) throws {
        try writeAtomic(try dir(id, recordings: recordings).appendingPathComponent("notes.json"), try encodeJSON(notes))
    }

    public static func loadNotes(_ id: String, recordings: URL = Paths.recordings) -> [Note] {
        (try? dir(id, recordings: recordings)).map(notes(in:)) ?? []
    }

    /// The notes typed for the recording whose folder this is.
    static func notes(in dir: URL) -> [Note] { tryJSON([Note].self, dir.appendingPathComponent("notes.json")) ?? [] }

    public static func discard(_ id: String, recordings: URL = Paths.recordings) throws {
        try FileManager.default.removeItem(at: try dir(id, recordings: recordings))
    }

    static func deleteAudio(_ rec: Recording) {
        for name in audioTracks + ["clips"] { try? FileManager.default.removeItem(at: rec.dir.appendingPathComponent(name)) }
    }

    /// The call's tracks, but not the short clips who's who plays.
    static func deleteTracks(_ dir: URL) {
        for name in audioTracks { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    public static func savedInfo(_ dir: URL) -> SavedInfo? { tryJSON(SavedInfo.self, dir.appendingPathComponent("saved.json")) }

    /// Recordings saved as meetings without checking who's who: their voices can still be named.
    public static func unchecked(recordings: URL = Paths.recordings) -> [Recording] {
        list(recordings: recordings).filter { $0.state == .saved && savedInfo($0.dir)?.isUnchecked == true }
    }

    /// Keep as is: the meeting stays as it was saved, and the recording's working folder can go (tidySaved).
    public static func markChecked(_ rec: Recording) throws {
        let info = savedInfo(rec.dir) ?? SavedInfo(meeting: nil)
        try writeAtomic(rec.dir.appendingPathComponent("saved.json"), try encodeJSON(SavedInfo(meeting: info.meeting)) + "\n")
    }

    /// Where a saved recording's meeting is now, relative to the Meetings folder (it may have been moved or renamed).
    public static func meetingPath(_ rec: Recording, meetingsRoot: URL) -> String? {
        guard let dir = savedMeeting(rec.id, savedInfo(rec.dir)?.meeting, under: meetingsRoot) else { return nil }
        let root = meetingsRoot.standardizedFileURL.path, path = dir.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    /**
     * Clears away the working folders of recordings that have been saved as meetings. One whose audio
     * was kept (Keep call audio) first has it written into its meeting's folder as audio.m4a, so it's
     * with the meeting and goes to the Trash with it; if that can't be written, the folder stays to be
     * tried again, and what went wrong is returned to be said. One whose meeting has gone (to the
     * Trash, say) goes too, so its meeting isn't searched for through the whole Meetings folder every
     * time: to the Trash if it still holds audio, deleted if not. Not when the whole Meetings folder is
     * missing (a drive that isn't plugged in): that's no sign of what happened to one meeting. Slow for
     * kept audio, so it's run in the background: at launch and after each save.
     */
    @discardableResult
    public static func tidySaved(meetingsRoot: URL, recordings: URL = Paths.recordings,
                                 trash: (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [String] {
        let fm = FileManager.default
        var problems: [String] = []
        for id in (try? fm.contentsOfDirectory(atPath: recordings.path)) ?? [] {
            let dir = recordings.appendingPathComponent(id, isDirectory: true)
            guard let saved = savedInfo(dir) else { continue }
            let hasTracks = audioTracks.contains { size(dir.appendingPathComponent($0)) > 0 }
            guard hasTracks || saved.isUnchecked else {
                try? fm.removeItem(at: dir)
                continue
            }
            guard let meeting = savedMeeting(id, saved.meeting, under: meetingsRoot) else {
                // Audio that never reached its meeting is the only copy, so it goes to the Trash, where
                // it can still be got back, rather than being deleted.
                if fm.exists(meetingsRoot) {
                    if hasTracks { trash(dir) } else { try? fm.removeItem(at: dir) }
                }
                continue
            }
            if hasTracks {
                let audio = meeting.appendingPathComponent("audio.m4a")
                if !fm.exists(audio) {
                    do {
                        try exportAudio(recording: dir, to: audio)
                    } catch {
                        let title = tryJSON(CallInfo.self, dir.appendingPathComponent("call.json"))?.title ?? id
                        problems.append("The call audio of “\(title)” couldn’t be kept with its meeting: \(error.localizedDescription)")
                        continue
                    }
                }
            }
            // Its voices can still be named: the analysis and clips stay, the tracks have gone to the meeting.
            if saved.isUnchecked {
                deleteTracks(dir)
            } else {
                try? fm.removeItem(at: dir)
            }
        }
        return problems
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

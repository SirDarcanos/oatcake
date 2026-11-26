// Markdown typed into a meeting that isn't on disk yet. The app keeps it, not the meeting's window, so
// it can still be written when Oatcake quits or installs an update, and so quitting can ask first about
// any that couldn't be.

import Foundation

/// The Markdown edits waiting to be written, by meeting and file.
public struct MeetingEdits: Equatable, Sendable {
    public struct Key: Hashable, Sendable {
        /// The meeting, relative to the Meetings folder.
        public var meeting: String
        public var file: MeetingFile
    }

    public struct Edit: Equatable, Sendable {
        public var text: String
        /// The file as it was before this was typed: it's only written over while it's still that.
        public var loaded: String
        /// The last try at writing it failed.
        public var failed = false
    }

    /// How saving went for an edit that wasn't simply written.
    public enum Outcome: Equatable, Sendable {
        /// Its file had changed since it was read, so the edit went beside it under this name instead.
        case setAside(Key, String)
        /// It couldn't be written (why is given), and is still waiting.
        case failed(Key, String)
    }

    public private(set) var waiting: [Key: Edit] = [:]

    public init() {}

    /// What's typed into `file` now. `before` is the text it showed until this, which is what's on disk
    /// unless an edit to it was waiting already (then that edit's `loaded` stays).
    public mutating func typed(_ text: String, in meeting: String, _ file: MeetingFile, before: String) {
        let key = Key(meeting: meeting, file: file)
        if waiting[key] == nil {
            waiting[key] = Edit(text: text, loaded: before)
        } else {
            waiting[key]?.text = text
        }
    }

    /// The text waiting to be written to each of a meeting's files.
    public func texts(in meeting: String) -> [MeetingFile: String] {
        Dictionary(uniqueKeysWithValues: waiting.filter { $0.key.meeting == meeting }.map { ($0.key.file, $0.value.text) })
    }

    public func isWaiting(in meeting: String) -> Bool { waiting.keys.contains { $0.meeting == meeting } }

    /// Some edit couldn't be written the last time it was tried, to a meeting that's still there. One
    /// whose folder has gone (deleted or moved in Finder) has nowhere to go, so there's nothing to ask about.
    public func hasFailed(in meetings: Meetings) -> Bool {
        waiting.contains { key, edit in
            edit.failed && (try? resolveInside(meetings.root, key.meeting)).map { FileManager.default.exists($0) } == true
        }
    }

    /**
     * Writes what's waiting, in one meeting or in all of them. Whatever is written stops waiting. So does
     * an edit whose file has changed since it was read: what's there now stays, and the edit is put
     * beside it (Meetings.setAside). One that can't be written waits, marked as failed.
     */
    @discardableResult
    public mutating func save(to meetings: Meetings, in meeting: String? = nil) -> [Outcome] {
        var outcomes: [Outcome] = []
        for (key, edit) in waiting where meeting == nil || key.meeting == meeting {
            do {
                if try !meetings.write(key.meeting, key.file, edit.text, ifUnchangedFrom: edit.loaded) {
                    outcomes.append(.setAside(key, try meetings.setAside(key.meeting, key.file, edit.text)))
                }
                waiting.removeValue(forKey: key)
            } catch {
                waiting[key]?.failed = true
                outcomes.append(.failed(key, error.localizedDescription))
            }
        }
        return outcomes
    }

    /// Meetings or folders have gone to the Trash: what's waiting for them, or for anything in them, goes too.
    public mutating func discard(_ paths: [String]) {
        waiting = waiting.filter { key, _ in !paths.contains { key.meeting == $0 || key.meeting.hasPrefix($0 + "/") } }
    }

    /// A meeting or folder has been renamed or moved: `remap` gives a path's new place.
    public mutating func moved(_ remap: (String) -> String) {
        waiting = Dictionary(waiting.map { (Key(meeting: remap($0.key.meeting), file: $0.key.file), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}

import Foundation

/**
 * Prep notes written on New recording, kept until the call is recorded: you can write them hours
 * ahead, go and look at something else, and find them there when you come back. They're kept per
 * calendar event (one occurrence of it), or under "" for a recording that isn't from the calendar.
 * Once the call starts they become the first lines of its notes and are forgotten here.
 *
 * An occurrence is known by the event's UID and its day, not its start time: a call moved from two
 * o'clock to three keeps its prep.
 */
public enum PrepNotes {
    struct Entry: Codable, Equatable {
        var notes: [String]
        var savedAt: String
    }

    /// Prep for a call that never got recorded isn't kept for ever.
    static let keptFor: TimeInterval = 30 * 86_400

    public static func load(_ event: String?, from file: URL = Paths.prep) -> [String] {
        let entries = all(file)
        // Prep saved by an earlier version is under the event's whole id.
        return (entries[key(event)] ?? entries[event ?? ""])?.notes ?? []
    }

    /// What an event's prep is kept under: "<uid>@2026-11-05" for the id "<uid>@2026-11-05T14:00:00.000Z"
    /// (the day in your own time zone). Anything that isn't such an id is its own key.
    static func key(_ event: String?) -> String {
        guard let event, let at = event.lastIndex(of: "@"), let start = parseISO(String(event[event.index(after: at)...])) else { return event ?? "" }
        let day = gregorian.dateComponents([.year, .month, .day], from: start)
        return "\(event[..<at])@" + String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Saving none forgets the event's prep.
    public static func save(_ event: String?, _ notes: [String], to file: URL = Paths.prep, now: Date = Date()) throws {
        var entries = all(file).filter { now.timeIntervalSince(parseISO($0.value.savedAt) ?? .distantPast) < keptFor }
        let kept = notes.map(\.trimmed).filter { !$0.isEmpty }
        entries[event ?? ""] = nil
        entries[key(event)] = kept.isEmpty ? nil : Entry(notes: kept, savedAt: isoString(now))
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeAtomic(file, try encodeJSON(entries) + "\n")
        }
    }

    private static func all(_ file: URL) -> [String: Entry] { tryJSON([String: Entry].self, file) ?? [:] }
}

/**
 * Typed or pasted text as prep notes, one per line: an agenda pasted from an email or a document
 * comes in as its points, without the bullets, numbers or tick boxes they were listed with.
 */
public func prepLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).compactMap { line in
        let point = line.replacingOccurrences(of: #"^\s*(?:(?:[-*•–—·▪◦‣]|\d{1,3}[.)])\s+)?(?:\[[ xX]?\]\s+)?"#, with: "", options: .regularExpression).trimmed
        return point.isEmpty ? nil : point
    }
}

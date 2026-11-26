// Which call reminders have gone out, kept in Oatcake's data folder: opening Oatcake again within
// a call's reminder time (an update does that) doesn't remind of it again, with its sound.

import Foundation

public struct SentReminders: Codable, Equatable, Sendable {
    /// "<event ID> <minutes>" for each reminder that has gone out, with when its event starts.
    private var sent: [String: String] = [:]

    public init() {}

    public static func load(_ file: URL = Paths.reminders) -> SentReminders { tryJSON(SentReminders.self, file) ?? SentReminders() }

    public func save(to file: URL = Paths.reminders) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(file, try encodeJSON(self) + "\n")
    }

    /**
     * The calls to remind of at `now`: each timed event once for each of `minutes`, from that many
     * minutes before it starts until a minute after (the Mac may have been asleep). When several of
     * an event's times have come at once (Oatcake was opened a minute before it), one reminder
     * covers them. None for `recording`, the call being recorded: the reminder's sound would go
     * into the recording, and there's nothing to remind of.
     */
    public mutating func due(_ events: [CalendarEvent], minutes: [Int], at now: Date, recording: String? = nil) -> [CalendarEvent] {
        // A day after a call started, it can't be reminded of any more.
        sent = sent.filter { (parseISO($0.value) ?? .distantPast) > now.addingTimeInterval(-86_400) }
        var due: [CalendarEvent] = []
        for event in events where !event.allDay && event.id != recording {
            let until = event.startDate.timeIntervalSince(now)
            guard until >= -60 else { continue }
            let come = Set(minutes).filter { until <= Double($0) * 60 }
            guard come.contains(where: { sent["\(event.id) \($0)"] == nil }) else { continue }
            for m in come { sent["\(event.id) \(m)"] = event.start }
            due.append(event)
        }
        return due
    }
}

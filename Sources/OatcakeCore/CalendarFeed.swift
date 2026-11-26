// Each calendar's private iCal address: fetched at most once an hour, its events from a day ago to
// two weeks ahead kept in its own cache file (CalendarSource.cacheFile). The feed's text is read in
// ICalReader.swift, and its recurring events are expanded in Recurrence.swift.

import Foundation

public struct CalendarEvent: Codable, Identifiable, Equatable, Hashable, Sendable {
    public struct Attendee: Codable, Equatable, Hashable, Sendable {
        public var name: String?
        public var email: String
        /// They declined the invite. nil when they didn't (and in caches written before this was kept).
        public var declined: Bool?
        /// A room or other resource on the invite, not a person.
        public var resource: Bool?

        // Who they are, not how they answered.
        public static func == (a: Attendee, b: Attendee) -> Bool { a.name == b.name && a.email == b.email }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(email)
        }
    }
    /// Unique per occurrence.
    public var id: String
    /// Shared by every occurrence of a recurring event.
    public var seriesId: String?
    public var title: String
    public var start: String
    public var end: String
    public var allDay: Bool
    public var attendees: [Attendee]
    public var meetUrl: String?

    /// The same event, down to how each person answered (two attendees are the same person whatever they answered).
    public static func == (a: CalendarEvent, b: CalendarEvent) -> Bool {
        let replies = { (e: CalendarEvent) in e.attendees.map { [$0.declined ?? false, $0.resource ?? false] } }
        return a.id == b.id && a.seriesId == b.seriesId && a.title == b.title && a.start == b.start && a.end == b.end
            && a.allDay == b.allDay && a.attendees == b.attendees && replies(a) == replies(b) && a.meetUrl == b.meetUrl
    }

    public var startDate: Date { parseISO(start) ?? .distantPast }
    public var endDate: Date { parseISO(end) ?? .distantPast }
    /// The call link, if it's a real Meet, Zoom or Teams address (checked again: the cache may predate the check).
    public var callLink: String? { meetUrl.flatMap { callApp($0) != nil ? $0 : nil } }
}

public struct CalendarCache: Codable, Equatable, Sendable {
    /// Last fetch attempt, successful or not.
    public var checkedAt: String?
    /// Last successful fetch.
    public var updatedAt: String?
    /// Why the last fetch failed, if it did: the reason alone ("the calendar took too long to answer").
    public var error: String?
    public var events: [CalendarEvent]

    public init(checkedAt: String? = nil, updatedAt: String? = nil, error: String? = nil, events: [CalendarEvent] = []) {
        self.checkedAt = checkedAt
        self.updatedAt = updatedAt
        self.error = error
        self.events = events
    }

    /// The failed fetch as a sentence to show.
    public var failure: String? { error.map { Self.failurePrefix + $0 } }
    static let failurePrefix = "Couldn't update the calendar: "

    public static func load(_ file: URL = Paths.calendar) -> CalendarCache { tryJSON(CalendarCache.self, file) ?? CalendarCache() }

    public func save(to file: URL = Paths.calendar) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(file, try encodeJSON(self), permissions: 0o600)
    }

    /// Fresh for an hour; the refresh button fetches regardless.
    public func isStale(now: Date = Date()) -> Bool {
        guard let checked = parseISO(checkedAt) else { return true }
        return now.timeIntervalSince(checked) >= 3600
    }
}

extension CalendarCache {
    // Read field by field for one reason: a cache written by an earlier version kept the whole
    // sentence in `error`, and the reason is taken back out of it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        events = try c.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error).map { $0.hasPrefix(Self.failurePrefix) ? String($0.dropFirst(Self.failurePrefix.count)) : $0 }
    }
}

/// Timed calls still in progress or starting before the end of tomorrow, in the supplied order.
public func upcomingCalls(_ events: [CalendarEvent], at now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
    guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return [] }
    return events.filter { !$0.allDay && $0.endDate > now && $0.startDate < end }
}

/**
 * The event happening at `now` (or starting within ten minutes), if any. None if that event is in
 * `recorded` (by ID): a call that finishes early and is followed by another while its slot is still on
 * the clock (a quick debrief, say) would otherwise be named after the first call and get its invite.
 */
public func eventHappening(_ events: [CalendarEvent], at now: Date, unless recorded: Set<String> = []) -> CalendarEvent? {
    let event = events.first { !$0.allDay && $0.startDate.addingTimeInterval(-600) <= now && $0.endDate > now }
    return event.flatMap { recorded.contains($0.id) ? nil : $0 }
}

/**
 * Whether an event is left out of Upcoming, the menu bar and reminders: its title starts with one of
 * `ignored` (Settings › Calendars) as whole words, or has "Oatcake ignore" anywhere in it. Case and
 * surrounding spaces don't count. iCal doesn't say which events are Google's focus time or
 * out-of-office blocks, so their titles are all there is to go on.
 */
public func ignoredEvent(_ title: String, _ ignored: [String]) -> Bool {
    let title = title.trimmed.lowercased()
    if title.contains("oatcake ignore") { return true }
    return ignored.contains { entry in
        let entry = entry.trimmed.lowercased()
        guard !entry.isEmpty, title.hasPrefix(entry) else { return false }
        // "Task" leaves out "Task: file report", not "Taskforce sync".
        return title.dropFirst(entry.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
    }
}

/**
 * An event you've told Oatcake to ignore from Upcoming: one occurrence, or every occurrence of a
 * recurring event. Kept in config.json and only there: the calendar isn't changed and nobody else
 * sees it. Upcoming only shows events that haven't ended, so ignoring a series from one of its
 * occurrences is ignoring that one and the ones after it.
 *
 * Two changes on the calendar's side bring one back: an occurrence the organiser moves gets a new ID
 * (its ID is the event's UID and start), and Google's "this and following events" edit gives the rest
 * of a series a new UID.
 */
public struct IgnoredEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The occurrence's ID (CalendarEvent.id), or for a series its seriesId.
    public var id: String
    /// Every occurrence of a recurring event, not just one.
    public var series: Bool
    /// What Settings › Calendars lists it as.
    public var title: String
    /// When the occurrence starts and ends; nil for a series. Once it has ended it's forgotten.
    public var start: String?
    public var end: String?

    public static func occurrence(_ e: CalendarEvent) -> IgnoredEvent {
        IgnoredEvent(id: e.id, series: false, title: e.title, start: e.start, end: e.end)
    }

    /// nil for an event that doesn't recur.
    public static func series(of e: CalendarEvent) -> IgnoredEvent? {
        e.seriesId.map { IgnoredEvent(id: $0, series: true, title: e.title, start: nil, end: nil) }
    }

    /// The same choice: the same occurrence, or the same series.
    public func covers(_ other: IgnoredEvent) -> Bool { id == other.id && series == other.series }
}

/// Whether Upcoming's Ignore covers this event: the occurrence itself, or its whole series.
public func isIgnored(_ event: CalendarEvent, _ ignored: [IgnoredEvent]) -> Bool {
    ignored.contains { item in
        guard item.series else { return item.id == event.id }
        if let seriesId = event.seriesId { return item.id == seriesId }
        // A second feed may publish the same invite without its recurrence rule.
        return event.id == occurrenceID(uid: item.id, start: event.start)
    }
}

func occurrenceID(uid: String, start: String) -> String { "\(uid)@\(start)" }

/// Look up the reminder’s occurrence ID in the current, filtered calendar events.
public func currentEvent(forReminder id: String, in events: [CalendarEvent]) -> CalendarEvent? {
    events.first { $0.id == id }
}

/// Without ignored occurrences that have ended: there's nothing left of them to ignore.
public func withoutEnded(_ ignored: [IgnoredEvent], now: Date) -> [IgnoredEvent] {
    ignored.filter { $0.series || (parseISO($0.end) ?? .distantFuture) > now }
}

/// Video-call services, by the exact host (or parent domain) their links use.
private let callHosts: [(name: String, pattern: String)] = [
    ("Google Meet", #"^meet\.google\.com$"#),
    ("Zoom", #"^(?:[a-z0-9-]+\.)*zoom\.us$"#),
    ("Microsoft Teams", #"^teams\.microsoft\.com$"#),
]

/// "Google Meet", "Zoom" or "Microsoft Teams" for a call link; nil for anything else.
public func callApp(_ url: String) -> String? {
    guard let components = URLComponents(string: url), components.scheme == "https", let host = components.host?.lowercased() else { return nil }
    return callHosts.first { host.range(of: $0.pattern, options: .regularExpression) != nil }?.name
}

/**
 * The first video-call link in an event's text. Hosts are checked whole, so a look-alike such as
 * "meet.google.com.example.net" or "evilzoom.us" is never offered as the call.
 */
public func findCallLink(_ text: String) -> String? {
    let regex = try! NSRegularExpression(pattern: #"https://[^\s<>"']+"#, options: .caseInsensitive)
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range, in: text) else { continue }
        let url = String(text[range]).replacingOccurrences(of: #"[),.;\]]+$"#, with: "", options: .regularExpression)
        if callApp(url) != nil { return url }
    }
    return nil
}

/**
 * Downloads the calendar and keeps the events from a day ago to two weeks ahead. A failed fetch keeps
 * the previous events and records the error. The address is a secret, so it never appears in errors.
 */
public func fetchCalendar(_ address: String, previous: CalendarCache) async -> CalendarCache {
    let checkedAt = isoString(Date())
    let https = address.trimmed.replacingOccurrences(of: "^webcal:", with: "https:", options: [.regularExpression, .caseInsensitive])
    do {
        var request = URLRequest(url: try calendarURL(https), timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A session that keeps nothing on disk: the address is a secret, and the shared one's cache would hold it.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OatcakeError("the calendar address returned \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))".trimmed)
        }
        let calendar = parseICal(String(decoding: data, as: UTF8.self))
        guard calendar.name == "VCALENDAR", calendar.closed else {
            throw OatcakeError("the address didn’t return a complete iCal feed")
        }
        let now = Date()
        let events = parseCalendar(calendar, from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(14 * 86_400))
        return CalendarCache(checkedAt: checkedAt, updatedAt: checkedAt, error: nil, events: events)
    } catch {
        let message = (error as? URLError)?.code == .timedOut ? "the calendar took too long to answer"
            : (error as? OatcakeError)?.message ?? "Oatcake couldn’t reach the calendar"
        var cache = previous
        cache.checkedAt = checkedAt
        cache.error = message
        return cache
    }
}

/// The address to fetch: https only, so the secret in it isn't sent in the clear. (http is let
/// through for this Mac's own address, which is how a calendar is stood in for when trying things out.)
func calendarURL(_ address: String) throws -> URL {
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { throw OatcakeError("that isn't a web address") }
    let host = (url.host(percentEncoded: false) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
        throw OatcakeError("the calendar address has to start with https://")
    }
    guard !host.isEmpty else { throw OatcakeError("that isn't a web address") }
    return url
}

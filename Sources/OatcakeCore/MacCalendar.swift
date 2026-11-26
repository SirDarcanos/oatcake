// Events on this Mac's own calendars (the ones in its Calendar app), as the same CalendarEvent values
// an iCal feed gives, so Upcoming, reminders, the menu bar, call notices and folder matching treat
// them alike. The app reads them through EventKit (Sources/Oatcake/MacCalendars.swift) and hands
// them over as the plain values below, which can be tested without asking for calendar access.

import Foundation

/// What Oatcake takes from one event on this Mac's calendars (an occurrence, for a recurring one).
public struct MacEvent: Sendable {
    public struct Person: Sendable {
        public var name: String?
        /// Where EventKit says to reach them: "mailto:jane.doe@example.com" for most people.
        public var url: String?
        public var declined: Bool
        /// A room or other resource on the invite, not a person.
        public var resource: Bool
        /// The person whose calendar this is.
        public var isYou: Bool

        public init(name: String?, url: String?, declined: Bool = false, resource: Bool = false, isYou: Bool = false) {
            self.name = name
            self.url = url
            self.declined = declined
            self.resource = resource
            self.isYou = isYou
        }
    }

    /// The same for every occurrence of a recurring event: the server's ID for it, which for a Google
    /// or iCloud calendar is the invitation's UID, so the same call on a private iCal feed is the same event.
    public var uid: String
    public var title: String?
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var recurring: Bool
    public var cancelled: Bool
    public var url: String?
    public var location: String?
    public var notes: String?
    /// The organiser and everyone invited.
    public var people: [Person]

    public init(uid: String, title: String?, start: Date, end: Date, allDay: Bool = false, recurring: Bool = false,
                cancelled: Bool = false, url: String? = nil, location: String? = nil, notes: String? = nil, people: [Person] = []) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.recurring = recurring
        self.cancelled = cancelled
        self.url = url
        self.location = location
        self.notes = notes
        self.people = people
    }
}

/// The event as an iCal feed's would be; nil for one that's cancelled or that you declined, which a
/// feed leaves out too.
public func calendarEvent(_ event: MacEvent) -> CalendarEvent? {
    guard !event.cancelled, !event.people.contains(where: { $0.isYou && $0.declined }) else { return nil }
    // A whole-day event runs midnight to midnight, as a feed's does; EventKit can end one a second before.
    let start = event.allDay ? gregorian.startOfDay(for: event.start) : event.start
    let lastDay = max(gregorian.startOfDay(for: event.end.addingTimeInterval(-1)), start)
    let end = event.allDay ? gregorian.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay : event.end
    var seen = Set<String>()
    let attendees = event.people.compactMap { person -> CalendarEvent.Attendee? in
        let url = person.url ?? ""
        let email = url.range(of: "^mailto:", options: [.regularExpression, .caseInsensitive]).map { String(url[$0.upperBound...]).lowercased() } ?? ""
        let name = person.name.flatMap { $0.trimmed.isEmpty || $0.lowercased() == email ? nil : $0 }
        // The organiser is usually on the invite too.
        guard name != nil || !email.isEmpty, seen.insert(email.isEmpty ? name ?? "" : email).inserted else { return nil }
        return CalendarEvent.Attendee(name: name, email: email, declined: person.declined ? true : nil, resource: person.resource ? true : nil)
    }
    let stampedStart = isoString(start)
    let title = event.title?.trimmed ?? ""
    return CalendarEvent(id: occurrenceID(uid: event.uid, start: stampedStart), seriesId: event.recurring ? event.uid : nil,
                         title: title.isEmpty ? "Untitled event" : title, start: stampedStart, end: isoString(end),
                         allDay: event.allDay, attendees: attendees,
                         meetUrl: findCallLink([event.url, event.location, event.notes].compactMap { $0 }.joined(separator: " ")))
}

/**
 * One of this Mac's calendars, read: the events it has, or, when it couldn't be read (Oatcake isn't
 * allowed to, or the calendar has gone from this Mac), the events it had with why, tried again as a
 * feed that failed is (CalendarCache.isStale).
 */
public func macCalendarCache(_ read: Result<[MacEvent], OatcakeError>, previous: CalendarCache, now: Date = Date()) -> CalendarCache {
    let checkedAt = isoString(now)
    switch read {
    case .success(let events):
        return CalendarCache(checkedAt: checkedAt, updatedAt: checkedAt, events: events.compactMap(calendarEvent))
    case .failure(let error):
        var cache = previous
        cache.checkedAt = checkedAt
        cache.error = error.message
        cache.failures = (previous.error == nil ? 0 : previous.failures ?? 1) + 1
        return cache
    }
}

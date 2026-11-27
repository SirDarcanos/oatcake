import Foundation
@testable import OatcakeCore
import Testing

/// Events on this Mac's own calendars, from the plain values the app reads out of EventKit. Nothing
/// here asks EventKit for anything, so no permission is needed or asked for.
@Suite struct MacCalendarTests {
    let start = parseISO("2026-11-10T10:00:00Z")!
    var end: Date { start.addingTimeInterval(1800) }

    /// The call link is found in the event's URL, then its location, then its notes, as a feed's is in
    /// its conference field, location and description; a look-alike doesn't count.
    @Test func callLinkFromURLLocationOrNotes() throws {
        func link(url: String? = nil, location: String? = nil, notes: String? = nil) -> String? {
            calendarEvent(MacEvent(uid: "a", title: "Weekly sync", start: start, end: end, url: url, location: location, notes: notes))?.callLink
        }
        #expect(link(url: "https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij")
        #expect(link(location: "Zoom: https://acme.zoom.us/j/123") == "https://acme.zoom.us/j/123")
        #expect(link(notes: "Join (https://teams.microsoft.com/l/meetup-join/1).") == "https://teams.microsoft.com/l/meetup-join/1")
        #expect(link(url: "https://teams.microsoft.com/l/x", notes: "https://meet.google.com/abc-defg-hij") == "https://teams.microsoft.com/l/x")
        #expect(link(url: "https://meet.google.com.example.net/x", notes: "https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij")
        #expect(link(url: "https://example.com/agenda", location: "Room 4") == nil)
    }

    /// A whole-day event runs from midnight to midnight, as a feed's does, though EventKit ends it a
    /// second before.
    @Test func allDay() throws {
        let day = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        let lastSecond = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 23, minute: 59, second: 59))!
        let offsite = try #require(calendarEvent(MacEvent(uid: "offsite", title: "Offsite", start: day, end: lastSecond, allDay: true)))
        #expect(offsite.allDay && offsite.startDate == day)
        #expect(offsite.endDate == gregorian.date(from: DateComponents(year: 2026, month: 11, day: 14)))
        // Ending on the stroke of midnight is the same; ending as it starts is still one day.
        let midnight = gregorian.date(byAdding: .day, value: 1, to: day)!
        #expect(calendarEvent(MacEvent(uid: "b", title: "Holiday", start: day, end: midnight, allDay: true))?.endDate == midnight)
        #expect(calendarEvent(MacEvent(uid: "b", title: "Holiday", start: day, end: day, allDay: true))?.endDate == midnight)
        #expect(upcomingCalls([offsite], at: day.addingTimeInterval(3600)).isEmpty)
    }

    /// An event you declined is left out, as a feed's is, and so is one that's cancelled; someone else
    /// declining keeps it, with them marked.
    @Test func declinedAndCancelled() throws {
        let jane = MacEvent.Person(name: "Jane Doe", url: "mailto:jane@example.com")
        let you = MacEvent.Person(name: "John Smith", url: "mailto:john@example.com", declined: true, isYou: true)
        let declinedByJane = MacEvent.Person(name: "Jane Doe", url: "mailto:jane@example.com", declined: true)
        #expect(calendarEvent(MacEvent(uid: "a", title: "Planning", start: start, end: end, people: [jane, you])) == nil)
        #expect(calendarEvent(MacEvent(uid: "a", title: "Planning", start: start, end: end, cancelled: true, people: [jane])) == nil)
        let kept = try #require(calendarEvent(MacEvent(uid: "a", title: "Planning", start: start, end: end, people: [declinedByJane])))
        #expect(kept.attendees.map(\.declined) == [true])
    }

    /// Who's on the invite: the organiser and everyone invited, each once, by their address, with rooms
    /// marked so neither is offered as a name.
    @Test func attendees() throws {
        let event = try #require(calendarEvent(MacEvent(uid: "a", title: "  ", start: start, end: end, people: [
            MacEvent.Person(name: "Jane Doe", url: "mailto:Jane@Example.com"),
            MacEvent.Person(name: "Jane Doe", url: "mailto:jane@example.com"),
            MacEvent.Person(name: "john.smith@example.com", url: "MAILTO:john.smith@example.com"),
            MacEvent.Person(name: "Boardroom", url: "mailto:room@resource.example.com", resource: true),
            MacEvent.Person(name: "Joe Bloggs", url: "urn:uuid:0001"),
            MacEvent.Person(name: nil, url: "urn:uuid:0002"),
        ])))
        #expect(event.title == "Untitled event")
        #expect(event.attendees.map(\.email) == ["jane@example.com", "john.smith@example.com", "room@resource.example.com", ""])
        #expect(event.attendees.map(\.name) == ["Jane Doe", nil, "Boardroom", "Joe Bloggs"])
        #expect(event.attendees.map(\.resource) == [nil, nil, true, nil])
    }

    /// The same invitation on a private iCal feed and on this Mac's calendar is one event, under both
    /// calendars' dots, and Ignore for its series covers both.
    @Test func sameEventAsAFeed() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:weekly-sync@example.com
        DTSTART:20261110T100000Z
        DURATION:PT30M
        RRULE:FREQ=WEEKLY;COUNT=2
        SUMMARY:Weekly sync
        END:VEVENT
        END:VCALENDAR
        """
        let feed = parseCalendar(ics, from: parseISO("2026-11-09T00:00:00Z")!, to: parseISO("2026-11-12T00:00:00Z")!)
        let mac = try #require(calendarEvent(MacEvent(uid: "weekly-sync@example.com", title: "Weekly sync", start: start, end: end,
                                                      recurring: true, url: "https://meet.google.com/abc-defg-hij")))
        #expect(feed.map(\.id) == [mac.id] && feed.first?.seriesId == mac.seriesId)
        let work = UUID(), here = UUID()
        let merged = MergedCalendar([(work, feed), (here, [mac])])
        #expect(merged.events.count == 1 && merged.sourcesByEvent[mac.id] == [work, here])
        #expect(merged.events[0].callLink == "https://meet.google.com/abc-defg-hij")
        #expect(isIgnored(merged.events[0], [try #require(IgnoredEvent.series(of: mac))]))
        #expect(calendarEvent(MacEvent(uid: "one-off", title: "Planning", start: start, end: end))?.seriesId == nil)
    }

    /// A calendar that can't be read keeps what it had and says why, and is tried again as a feed that
    /// failed is.
    @Test func readsThatFail() throws {
        let now = start.addingTimeInterval(-3600)
        let read = macCalendarCache(.success([MacEvent(uid: "a", title: "Planning", start: start, end: end)]), previous: CalendarCache(), now: now)
        #expect(read.events.map(\.title) == ["Planning"] && read.updatedAt == isoString(now) && read.error == nil)
        let refused = OatcakeError("Oatcake isn’t allowed to read this Mac’s calendars")
        let failed = macCalendarCache(.failure(refused), previous: read, now: now.addingTimeInterval(60))
        #expect(failed.events == read.events && failed.updatedAt == read.updatedAt && failed.failures == 1)
        #expect(failed.failure == "Couldn't update the calendar: Oatcake isn’t allowed to read this Mac’s calendars")
        #expect(!failed.isStale(now: now.addingTimeInterval(90)) && failed.isStale(now: now.addingTimeInterval(120)))
        #expect(macCalendarCache(.failure(refused), previous: failed, now: now.addingTimeInterval(120)).failures == 2)
    }

    /// A calendar from this Mac is kept in private.json by its ID on this Mac, with no address and no
    /// cache file, and counts as connected.
    @Test func keptWithTheOtherCalendars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.json")
        let work = CalendarSource(name: "Work", colour: .blue, address: "https://example.com/work.ics")
        let home = CalendarSource(name: "Home", colour: CalendarSource.nextColour([work]), macCalendarID: "5D7A2C10-0000-4000-8000-000000000001")
        try CalendarSource.save([work, home], to: file)
        let loaded = try CalendarSource.load(from: file)
        #expect(loaded == [work, home])
        #expect(loaded[1].macCalendarID == home.macCalendarID && loaded[1].address.isEmpty && loaded[1].isConnected)
        #expect(home.colour != work.colour)

        var caches = CalendarFeedCaches()
        caches.setSources(loaded, in: root)
        let cache = CalendarCache(updatedAt: "2026-11-25T00:00:00Z")
        let accepted = caches.receive(cache, from: home.fetchID)
        #expect(accepted && caches[home.fetchID] == cache)
        #expect(!FileManager.default.fileExists(atPath: home.cacheFile(in: root).path))
        caches.setSources([work], in: root)
        let afterRemoval = caches.receive(cache, from: home.fetchID)
        #expect(!afterRemoval)
    }
}

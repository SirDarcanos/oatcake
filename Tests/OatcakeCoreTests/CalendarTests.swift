import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct CalendarTests {
    /// A byte-order mark in front, or an alarm left without its END, still reads as a whole feed.
    @Test func byteOrderMarkAndUnclosedAlarm() throws {
        let ics = "\u{FEFF}BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20261110T100000Z\r\nDTEND:20261110T110000Z\r\n"
            + "SUMMARY:Weekly sync\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let calendar = parseICal(ics)
        #expect(calendar.name == "VCALENDAR" && calendar.closed)
        let events = parseCalendar(ics, from: parseISO("2026-11-10T00:00:00Z")!, to: parseISO("2026-11-11T00:00:00Z")!)
        #expect(events.map(\.title) == ["Weekly sync"])
        // Cut off part-way: not a whole feed.
        #expect(!parseICal("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\n").closed)
    }

    @Test func upcomingCallsThroughTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 11pm Saturday local time, just before the spring clock change.
        let now = parseISO("2026-03-08T04:00:00Z")!
        func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, title: "Planning", start: start, end: end, allDay: allDay, attendees: [])
        }
        let events = [
            event("ended", "2026-03-08T03:00:00Z", "2026-03-08T04:00:00Z"),
            event("in progress", "2026-03-08T03:30:00Z", "2026-03-08T04:30:00Z"),
            event("next", "2026-03-08T04:15:00Z", "2026-03-08T04:45:00Z"),
            event("all day", "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", allDay: true),
            event("tomorrow", "2026-03-09T03:45:00Z", "2026-03-09T04:15:00Z"),
            event("too late", "2026-03-09T04:00:00Z", "2026-03-09T04:30:00Z"),
        ]
        #expect(upcomingCalls(events, at: now, calendar: calendar).map(\.id) == ["in progress", "next", "tomorrow"])
    }

    /// The same feed and window through ical.js (the Electron version) gave calendar-expected.json.
    @Test func matchesIcalJs() throws {
        let text = try String(contentsOf: fixture("calendar.ics"), encoding: .utf8)
        let expected = try JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: fixture("calendar-expected.json")))
        let events = parseCalendar(text, from: parseISO("2026-10-20T00:00:00Z")!, to: parseISO("2026-11-20T00:00:00Z")!)
        #expect(events.count == expected.count)
        // Whole-day events are days in the local time zone, so only their shape is compared.
        for (got, want) in zip(events.filter { !$0.allDay }, expected.filter { !$0.allDay }) {
            #expect(got == want, "\(got)\n vs \(want)")
        }
        let allDay = try #require(events.first { $0.allDay })
        #expect(allDay.title == "Offsite")
        #expect(allDay.endDate.timeIntervalSince(allDay.startDate) == 86_400)
    }

    /// Who's on an invite keeps how they answered and whether they're a room, so neither is offered as a name.
    @Test func attendees() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:1
        SUMMARY:Planning
        DTSTART:20261110T100000Z
        DTEND:20261110T103000Z
        ATTENDEE;CN=Jane Doe;PARTSTAT=ACCEPTED:mailto:jane@example.com
        ATTENDEE;CN=Jane Smith;PARTSTAT=DECLINED:mailto:jane.smith@example.com
        ATTENDEE;CUTYPE=RESOURCE;CN=London-6-Boardroom (10):mailto:room@resource.calendar.example.com
        END:VEVENT
        END:VCALENDAR
        """
        let event = try #require(parseCalendar(ics, from: parseISO("2026-11-10T00:00:00Z")!, to: parseISO("2026-11-11T00:00:00Z")!).first)
        #expect(event.attendees.map(\.email) == ["jane@example.com", "jane.smith@example.com", "room@resource.calendar.example.com"])
        #expect(event.attendees.map(\.declined) == [nil, true, nil])
        #expect(event.attendees.map(\.resource) == [nil, nil, true])
        // A cache written before these were kept still reads.
        let old = try JSONDecoder().decode(CalendarEvent.Attendee.self, from: Data(#"{"name":"Jane Doe","email":"jane@example.com"}"#.utf8))
        #expect(old == event.attendees[0] && old.declined == nil)
    }

    /// Events that aren't calls are left out by title, from the list in Settings › Calendar: at the
    /// start of the title as whole words, or "Oatcake ignore" anywhere. The feed itself keeps them all,
    /// so a change to the list counts straight away.
    @Test func eventsThatArentCalls() throws {
        let ignored = Config.defaultIgnoredEvents
        for title in ["Focus time", "Out of office", "Task", "Working location", "  FOCUS TIME  ", "out OF office", " task ",
                      "Focus time: read emails", "Out of office — holiday", "Task planning", "Working location: home",
                      "Oatcake ignore", "Lunch — Oatcake ignore", "Before OATCAKE IGNORE after"] {
            #expect(ignoredEvent(title, ignored), "\(title) should be left out")
        }
        for title in ["Sync", "Review focus time", "Discuss out of office coverage", "Weekly task review", "Taskforce sync",
                      "Tasks review", "Focus timeline", "Oatcake planning", "Ignore this reminder"] {
            #expect(!ignoredEvent(title, ignored), "\(title) should be kept")
        }
        #expect(!ignoredEvent("Focus time", []) && ignoredEvent("1:1 prep", ["1:1 prep", " "]) && !ignoredEvent("Sync", [" ", ""]))
        let from = parseISO("2026-11-01T00:00:00Z")!, to = parseISO("2026-12-01T00:00:00Z")!
        let ics = feed("DTSTART:20261110T100000Z", "DTEND:20261110T103000Z").replacingOccurrences(of: "SUMMARY:Sync", with: "SUMMARY:Focus time")
        #expect(parseCalendar(ics, from: from, to: to).map(\.title) == ["Focus time"])
        // Older settings without the list get Google's names; an emptied list stays empty.
        #expect(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).ignoredEvents == ignored)
        var config = Config.defaults()
        config.ignoredEvents = []
        #expect(try JSONDecoder().decode(Config.self, from: Data(try encodeJSON(config).utf8)).ignoredEvents == [])
    }

    /// Events ignored from Upcoming: one occurrence, or every occurrence of a recurring event. Another
    /// meeting with the same title isn't touched, and an ignored occurrence is forgotten once it has ended.
    @Test func eventsIgnoredFromUpcoming() throws {
        let from = parseISO("2026-11-01T00:00:00Z")!, to = parseISO("2026-12-01T00:00:00Z")!
        // Two weekly meetings with the same title, and a one-off.
        let weekly = feed("DTSTART:20261110T100000Z", "DTEND:20261110T103000Z", "RRULE:FREQ=WEEKLY;COUNT=3")
        let events = parseCalendar(weekly, from: from, to: to)
            + parseCalendar(weekly.replacingOccurrences(of: "UID:e", with: "UID:other"), from: from, to: to)
            + parseCalendar(feed("DTSTART:20261125T150000Z", "DTEND:20261125T160000Z").replacingOccurrences(of: "UID:e", with: "UID:once"), from: from, to: to)
        #expect(events.count == 7)
        let ours = events.filter { $0.seriesId == "e" }, oneOff = try #require(events.first { $0.seriesId == nil })
        func kept(_ ignored: [IgnoredEvent]) -> [String] { events.filter { !isIgnored($0, ignored) }.map(\.id) }

        // One occurrence: only that one.
        let one = [IgnoredEvent.occurrence(ours[1])]
        #expect(kept(one) == events.map(\.id).filter { $0 != ours[1].id })
        // The series, from any occurrence: all of ours, none of the other meeting with the same title.
        let series = [try #require(IgnoredEvent.series(of: ours[2]))]
        #expect(kept(series) == events.filter { $0.seriesId != "e" }.map(\.id))
        // A one-off has no series, and can be ignored on its own.
        #expect(IgnoredEvent.series(of: oneOff) == nil)
        #expect(kept([.occurrence(oneOff)]) == events.map(\.id).filter { $0 != oneOff.id })
        // An occurrence's ID is never taken for a series ID, or the other way round.
        #expect(!isIgnored(ours[0], [IgnoredEvent(id: "e", series: false, title: "Sync")]))
        #expect(!isIgnored(ours[0], [IgnoredEvent(id: ours[0].id, series: true, title: "Sync")]))

        // An occurrence is forgotten once it has ended; a series is kept.
        let all = one + series + [.occurrence(oneOff)]
        #expect(withoutEnded(all, now: parseISO("2026-11-17T10:29:00Z")!) == all)
        #expect(withoutEnded(all, now: parseISO("2026-11-17T10:30:00Z")!) == series + [.occurrence(oneOff)])
        #expect(withoutEnded(all, now: parseISO("2027-01-01T00:00:00Z")!) == series)
        #expect(series[0].covers(IgnoredEvent.series(of: ours[0])!) && !series[0].covers(one[0]))

        // Kept in the settings; older settings have none.
        var config = Config.defaults()
        config.ignoredCalendarEvents = all
        #expect(try JSONDecoder().decode(Config.self, from: Data(try encodeJSON(config).utf8)).ignoredCalendarEvents == all)
        #expect(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).ignoredCalendarEvents == [])
    }

    /// A call that finishes early and another in its slot: the second isn't named after the first.
    @Test func callAfterAnEarlyFinish() {
        func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, seriesId: nil, title: id, start: start, end: end, allDay: allDay, attendees: [], meetUrl: nil)
        }
        let renewal = event("Renewal sync", "2026-11-18T09:00:00Z", "2026-11-18T10:00:00Z")
        let next = event("Next call", "2026-11-18T10:00:00Z", "2026-11-18T11:00:00Z")
        let offsite = event("Offsite", "2026-11-18T00:00:00Z", "2026-11-19T00:00:00Z", allDay: true)
        func at(_ time: String) -> Date { parseISO("2026-11-18T\(time)Z")! }
        // As before when nothing has been recorded.
        #expect(eventHappening([offsite, renewal], at: at("09:01:00"))?.id == "Renewal sync")
        #expect(eventHappening([renewal], at: at("08:51:00"))?.id == "Renewal sync")
        #expect(eventHappening([renewal], at: at("08:49:00")) == nil)
        #expect(eventHappening([renewal, next], at: at("09:51:00"))?.id == "Renewal sync")
        #expect(eventHappening([renewal], at: at("10:00:00")) == nil)
        // Recorded already: no event, rather than its name or the next call's.
        #expect(eventHappening([renewal, next], at: at("09:47:00"), unless: ["Renewal sync"]) == nil)
        #expect(eventHappening([renewal, next], at: at("09:51:00"), unless: ["Renewal sync"]) == nil)
        #expect(eventHappening([renewal, next], at: at("09:51:00"), unless: ["Other call"])?.id == "Renewal sync")
    }

    @Test func callLinks() {
        #expect(callApp("https://meet.google.com/abc") == "Google Meet")
        #expect(callApp("https://acme.zoom.us/j/1") == "Zoom")
        #expect(callApp("https://evilzoom.us/j/1") == nil)
        #expect(callApp("https://meet.google.com.example.net/x") == nil)
        #expect(callApp("http://meet.google.com/abc") == nil)
        #expect(findCallLink("see (https://meet.google.com/abc-defg-hij).") == "https://meet.google.com/abc-defg-hij")
    }

    /// A feed can say anything: a rule no calendar would write is read without stopping the app.
    /// (Both feeds are written here, to RFC 5545's shape, with numbers at the edge of what an Int holds.)
    @Test func rulesNoCalendarWouldWrite() {
        func feed(_ rule: String) -> String {
            "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:Odd\nDTSTART:20261101T100000Z\nDTEND:20261101T103000Z\nRRULE:\(rule)\nEND:VEVENT\nEND:VCALENDAR\n"
        }
        let from = parseISO("2026-10-31T00:00:00Z")!, to = parseISO("2026-11-14T00:00:00Z")!
        #expect(parseCalendar(feed("FREQ=YEARLY;INTERVAL=9223372036854775807"), from: from, to: to).map(\.start) == ["2026-11-01T10:00:00.000Z"])
        #expect(parseCalendar(feed("FREQ=MONTHLY;BYDAY=-9223372036854775808MO"), from: from, to: to).count == 1)
        #expect(parseCalendar(feed("FREQ=MONTHLY;INTERVAL=9223372036854775807;BYMONTHDAY=-9223372036854775808"), from: from, to: to).isEmpty)
    }

    /// One occurrence of a weekly meeting, four weeks out, moved to this week: it's in this week's events.
    /// (Written here, to RFC 5545's shape: 2026-11-02 is a Monday.)
    @Test func anOccurrenceMovedIntoTheWindow() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:w
        SUMMARY:Weekly
        DTSTART:20261102T100000Z
        DTEND:20261102T103000Z
        RRULE:FREQ=WEEKLY
        END:VEVENT
        BEGIN:VEVENT
        UID:w
        RECURRENCE-ID:20261130T100000Z
        SUMMARY:Weekly, moved
        DTSTART:20261106T150000Z
        DTEND:20261106T153000Z
        END:VEVENT
        END:VCALENDAR
        """
        let events = parseCalendar(ics, from: parseISO("2026-11-03T00:00:00Z")!, to: parseISO("2026-11-17T00:00:00Z")!)
        #expect(events.map(\.start) == ["2026-11-06T15:00:00.000Z", "2026-11-09T10:00:00.000Z", "2026-11-16T10:00:00.000Z"])
        #expect(events.first?.title == "Weekly, moved" && events.first?.seriesId == "w")
    }

    /// Outlook names zones its own way ("GMT Standard Time"), which macOS doesn't know: the zone's own
    /// offsets are used, not this Mac's zone. (Written here, in the shape RFC 5545 gives a VTIMEZONE.)
    @Test func zonesKnownOnlyByTheirOffsets() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VTIMEZONE
        TZID:GMT Standard Time
        BEGIN:STANDARD
        DTSTART:16011028T020000
        TZOFFSETFROM:+0100
        TZOFFSETTO:+0000
        RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010325T010000
        TZOFFSETFROM:+0000
        TZOFFSETTO:+0100
        RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3
        END:DAYLIGHT
        END:VTIMEZONE
        BEGIN:VTIMEZONE
        TZID:India Standard Time
        BEGIN:STANDARD
        DTSTART:16010101T000000
        TZOFFSETFROM:+0530
        TZOFFSETTO:+0530
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:summer
        SUMMARY:Summer
        DTSTART;TZID=GMT Standard Time:20260710T140000
        DTEND;TZID=GMT Standard Time:20260710T143000
        END:VEVENT
        BEGIN:VEVENT
        UID:winter
        SUMMARY:Winter
        DTSTART;TZID=GMT Standard Time:20261110T140000
        DTEND;TZID=GMT Standard Time:20261110T143000
        END:VEVENT
        BEGIN:VEVENT
        UID:india
        SUMMARY:India
        DTSTART;TZID=India Standard Time:20261111T140000
        DTEND;TZID=India Standard Time:20261111T143000
        END:VEVENT
        END:VCALENDAR
        """
        let events = parseCalendar(ics, from: parseISO("2026-07-01T00:00:00Z")!, to: parseISO("2026-12-01T00:00:00Z")!)
        #expect(events.map(\.start) == ["2026-07-10T13:00:00.000Z", "2026-11-10T14:00:00.000Z", "2026-11-11T08:30:00.000Z"])
    }

    /// The calendar's address is a secret, so it's only ever asked for over https.
    @Test func addresses() throws {
        #expect(try calendarURL("https://calendar.example.com/private.ics").host() == "calendar.example.com")
        // This Mac's own address, for a calendar that's stood in for.
        #expect(try calendarURL("http://127.0.0.1:8000/x.ics").port == 8000)
        #expect(try calendarURL("http://[::1]:8000/x.ics").port == 8000)
        for address in ["http://calendar.example.com/private.ics", "file:///etc/hosts", "ftp://localhost/x.ics"] {
            #expect(throws: OatcakeError("the calendar address has to start with https://")) { try calendarURL(address) }
        }
    }

    /// One event, as a feed: `lines` are its own properties. (Every feed below is written here, to RFC 5545's shape.)
    private func feed(_ lines: String...) -> String {
        (["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:e", "SUMMARY:Sync"] + lines + ["END:VEVENT", "END:VCALENDAR"]).joined(separator: "\n")
    }

    private func starts(_ ics: String, from: String, to: String) -> [String] {
        parseCalendar(ics, from: parseISO(from)!, to: parseISO(to)!).map(\.start)
    }

    /// The rest of what a recurrence rule can say. 2026-10-30 is a Friday and the last weekday of its
    /// month; 2026-11-30 is a Monday.
    @Test func rulesByDayOfMonthPositionAndYear() {
        let autumn = (from: "2026-10-01T00:00:00Z", to: "2027-01-01T00:00:00Z")
        // Extra dates with no rule: the start and each of them.
        #expect(starts(feed("DTSTART:20261103T100000Z", "DTEND:20261103T103000Z", "RDATE:20261105T100000Z,20261109T100000Z"), from: autumn.from, to: autumn.to)
            == ["2026-11-03T10:00:00.000Z", "2026-11-05T10:00:00.000Z", "2026-11-09T10:00:00.000Z"])
        // Every year, from two years back.
        #expect(starts(feed("DTSTART:20241110T100000Z", "RRULE:FREQ=YEARLY"), from: autumn.from, to: autumn.to) == ["2026-11-10T10:00:00.000Z"])
        // The 15th and the last day of each month.
        #expect(starts(feed("DTSTART:20261015T100000Z", "RRULE:FREQ=MONTHLY;BYMONTHDAY=15,-1"), from: autumn.from, to: autumn.to)
            == ["2026-10-15T10:00:00.000Z", "2026-10-31T10:00:00.000Z", "2026-11-15T10:00:00.000Z", "2026-11-30T10:00:00.000Z", "2026-12-15T10:00:00.000Z", "2026-12-31T10:00:00.000Z"])
        // The last weekday of each month.
        #expect(starts(feed("DTSTART:20261030T160000Z", "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"), from: autumn.from, to: autumn.to)
            == ["2026-10-30T16:00:00.000Z", "2026-11-30T16:00:00.000Z", "2026-12-31T16:00:00.000Z"])
        // The last Friday, and the second Tuesday.
        #expect(starts(feed("DTSTART:20261030T160000Z", "RRULE:FREQ=MONTHLY;BYDAY=-1FR"), from: autumn.from, to: autumn.to)
            == ["2026-10-30T16:00:00.000Z", "2026-11-27T16:00:00.000Z", "2026-12-25T16:00:00.000Z"])
        #expect(starts(feed("DTSTART:20261013T160000Z", "RRULE:FREQ=MONTHLY;BYDAY=2TU"), from: autumn.from, to: autumn.to)
            == ["2026-10-13T16:00:00.000Z", "2026-11-10T16:00:00.000Z", "2026-12-08T16:00:00.000Z"])
    }

    /// The day a week starts on changes which weeks "every other week" means. RFC 5545's own example
    /// (section 3.8.5.3): with Monday, 5, 10, 19 and 24 August 1997; with Sunday, 5, 17, 19 and 31.
    @Test func theDayAWeekStartsOn() {
        let rule = "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST="
        let august = { (ics: String) in parseCalendar(ics, from: parseISO("1997-08-01T00:00:00Z")!, to: parseISO("1997-10-01T00:00:00Z")!).map { String($0.start.prefix(10)) } }
        #expect(august(feed("DTSTART;TZID=America/New_York:19970805T090000", rule + "MO")) == ["1997-08-05", "1997-08-10", "1997-08-19", "1997-08-24"])
        #expect(august(feed("DTSTART;TZID=America/New_York:19970805T090000", rule + "SU")) == ["1997-08-05", "1997-08-17", "1997-08-19", "1997-08-31"])
    }

    /// Whole days, and a time with no zone, are in whichever zone this Mac is in.
    @Test func wholeDaysAndTimesWithNoZone() {
        let local = { (day: Int, hour: Int) in isoString(gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!) }
        let days = parseCalendar(feed("DTSTART;VALUE=DATE:20261102", "RRULE:FREQ=WEEKLY;COUNT=3"), from: parseISO("2026-10-30T00:00:00Z")!, to: parseISO("2026-12-01T00:00:00Z")!)
        #expect(days.map(\.start) == [local(2, 0), local(9, 0), local(16, 0)])
        #expect(days.allSatisfy { $0.allDay && $0.endDate.timeIntervalSince($0.startDate) == 86_400 && $0.seriesId == "e" })
        let floating = parseCalendar(feed("DTSTART:20261110T090000", "DTEND:20261110T093000"), from: parseISO("2026-11-01T00:00:00Z")!, to: parseISO("2026-12-01T00:00:00Z")!)
        #expect(floating.map(\.start) == [local(10, 9)] && floating.first?.allDay == false && floating.first?.seriesId == nil)
    }

    /// A rule that ends on a day includes that day, and a day taken out of a series takes its meeting with it.
    @Test func endingOnADayAndSkippingADay() {
        let window = (from: "2026-11-01T00:00:00Z", to: "2026-11-30T00:00:00Z")
        #expect(starts(feed("DTSTART:20261102T100000Z", "RRULE:FREQ=DAILY;UNTIL=20261104"), from: window.from, to: window.to)
            == ["2026-11-02T10:00:00.000Z", "2026-11-03T10:00:00.000Z", "2026-11-04T10:00:00.000Z"])
        // An end given as a time is that moment, as before.
        #expect(starts(feed("DTSTART:20261102T100000Z", "RRULE:FREQ=DAILY;UNTIL=20261104T090000Z"), from: window.from, to: window.to)
            == ["2026-11-02T10:00:00.000Z", "2026-11-03T10:00:00.000Z"])
        // New York is five hours behind UTC in November.
        #expect(starts(feed("DTSTART;TZID=America/New_York:20261102T100000", "RRULE:FREQ=DAILY;COUNT=4", "EXDATE;VALUE=DATE:20261103"), from: window.from, to: window.to)
            == ["2026-11-02T15:00:00.000Z", "2026-11-04T15:00:00.000Z", "2026-11-05T15:00:00.000Z"])
        #expect(starts(feed("DTSTART;TZID=America/New_York:20261102T100000", "RRULE:FREQ=DAILY;COUNT=4", "EXDATE;TZID=America/New_York:20261103T100000"), from: window.from, to: window.to)
            == ["2026-11-02T15:00:00.000Z", "2026-11-04T15:00:00.000Z", "2026-11-05T15:00:00.000Z"])
    }

    /// The calendar is fetched again after an hour, and a fetch that only changes how somebody answered is a change.
    @Test func staleAndChanged() {
        let now = parseISO("2026-11-10T12:00:00Z")!
        #expect(CalendarCache().isStale(now: now))
        #expect(!CalendarCache(checkedAt: "2026-11-10T11:30:00Z").isStale(now: now))
        #expect(CalendarCache(checkedAt: "2026-11-10T10:59:59Z").isStale(now: now))

        let event = { (reply: String) in
            parseCalendar(self.feed("DTSTART:20261110T100000Z", "DTEND:20261110T103000Z", "ATTENDEE;CN=Jane Doe;PARTSTAT=\(reply):mailto:jane@example.com"),
                          from: parseISO("2026-11-01T00:00:00Z")!, to: parseISO("2026-11-30T00:00:00Z")!)[0]
        }
        let accepted = event("ACCEPTED"), declined = event("DECLINED")
        // The same person either way, and the same event until they answer differently.
        #expect(accepted.attendees == declined.attendees && accepted == event("ACCEPTED"))
        #expect(accepted != declined)
        #expect(CalendarCache(events: [accepted]) != CalendarCache(events: [declined]))
    }

    /// Why a fetch failed is kept as the reason alone, and said as a sentence where it's shown. A
    /// cache written by an earlier version kept the whole sentence: its reason is taken back out.
    @Test func failedFetches() throws {
        let failed = CalendarCache(checkedAt: "2026-11-10T11:30:00Z", error: "the calendar took too long to answer")
        #expect(failed.failure == "Couldn't update the calendar: the calendar took too long to answer")
        #expect(CalendarCache().failure == nil)
        let older = #"{"checkedAt":"2026-11-10T11:30:00.000Z","error":"Couldn't update the calendar: the calendar address returned 404 not found","events":[]}"#
        let read = try JSONDecoder().decode(CalendarCache.self, from: Data(older.utf8))
        #expect(read.error == "the calendar address returned 404 not found" && read.failure == "Couldn't update the calendar: the calendar address returned 404 not found")
        // As it's written now, it reads back as it was.
        #expect(try JSONDecoder().decode(CalendarCache.self, from: Data(try encodeJSON(failed).utf8)) == failed)
    }
}

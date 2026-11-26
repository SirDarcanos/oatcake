// A feed's events as the occurrences in a window of time: recurring events expanded (RRULE, EXDATE,
// RDATE, and moved or cancelled occurrences), in each event's own time zone.

import Foundation

struct ICalEvent {
    let component: ICalComponent
    let uid: String
    let start: ICalTime
    let duration: TimeInterval

    init?(_ component: ICalComponent, aliases: [String: TimeZone]) {
        guard let dtstart = component.first("DTSTART"),
              let start = parseICalTime(dtstart.value, tzid: dtstart.params["TZID"], valueType: dtstart.params["VALUE"], aliases: aliases) else { return nil }
        self.component = component
        uid = component.first("UID")?.value ?? UUID().uuidString
        self.start = start
        if let dtend = component.first("DTEND"),
           let end = parseICalTime(dtend.value, tzid: dtend.params["TZID"], valueType: dtend.params["VALUE"], aliases: aliases) {
            duration = end.date.timeIntervalSince(start.date)
        } else if let d = component.first("DURATION").flatMap({ parseDuration($0.value) }) {
            duration = d
        } else {
            duration = start.isDate ? 86_400 : 0
        }
    }

    var summary: String { component.first("SUMMARY").map { unescapeText($0.value) } ?? "" }
}

/// Expands an iCalendar feed into the occurrences that overlap [from, to).
public func parseCalendar(_ text: String, from: Date, to: Date) -> [CalendarEvent] {
    parseCalendar(parseICal(text), from: from, to: to)
}

func parseCalendar(_ calendar: ICalComponent, from: Date, to: Date) -> [CalendarEvent] {
    // VTIMEZONE blocks name zones; Outlook's own names ("GMT Standard Time") are matched through
    // the IANA location some feeds include alongside.
    var aliases: [String: TimeZone] = [:]
    for zone in calendar.components("VTIMEZONE") {
        guard let tzid = zone.first("TZID")?.value else { continue }
        if let location = zone.first("X-LIC-LOCATION")?.value, let tz = TimeZone(identifier: location) {
            aliases[tzid] = tz
        } else if TimeZone(identifier: tzid) == nil, let tz = zoneFromRules(zone) {
            aliases[tzid] = tz
        }
    }
    // A Google calendar named after its owner's address: used to drop events they declined.
    let owner = (calendar.first("X-WR-CALNAME")?.value ?? "").lowercased()

    var masters: [String: ICalEvent] = [:]
    // Moved, edited or cancelled occurrences of a recurring event come as separate entries with the
    // same UID, keyed here by the instant they replace (matching by instant works whatever time zone
    // either entry is written in).
    var replaced: [String: [Date: ICalComponent]] = [:]
    for component in calendar.components("VEVENT") {
        let uid = component.first("UID")?.value ?? ""
        if let rid = component.first("RECURRENCE-ID"),
           let instant = parseICalTime(rid.value, tzid: rid.params["TZID"], valueType: rid.params["VALUE"], aliases: aliases) {
            replaced[uid, default: [:]][instant.date] = component
        } else if let event = ICalEvent(component, aliases: aliases) {
            masters[uid] = event
        }
    }

    var events: [CalendarEvent] = []
    func add(_ event: ICalEvent, start: Date, end: Date, isDate: Bool, seriesId: String?) {
        guard end > from, start < to else { return }
        let c = event.component
        if (c.first("STATUS")?.value ?? "").uppercased() == "CANCELLED" { return }
        let attendees = c.all("ATTENDEE").map { p -> (email: String, name: String?, declined: Bool, resource: Bool) in
            let email = p.value.replacingOccurrences(of: "^mailto:", with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
            let name = p.params["CN"].flatMap { $0.isEmpty ? nil : $0 }
            return (email, name, (p.params["PARTSTAT"] ?? "").uppercased() == "DECLINED", ["RESOURCE", "ROOM"].contains((p.params["CUTYPE"] ?? "").uppercased()))
        }
        if !owner.isEmpty, attendees.contains(where: { $0.email == owner && $0.declined }) { return }
        // Google's own conference field first, then wherever else a link was pasted.
        let links = [c.first("X-GOOGLE-CONFERENCE")?.value, c.first("LOCATION")?.value, c.first("DESCRIPTION")?.value]
            .compactMap { $0.map(unescapeText) }.joined(separator: " ")
        let title = event.summary
        let stampedStart = isoString(start)
        events.append(CalendarEvent(
            id: occurrenceID(uid: event.uid, start: stampedStart), seriesId: seriesId, title: title.isEmpty ? "Untitled event" : title,
            start: stampedStart, end: isoString(end), allDay: isDate,
            attendees: attendees.map {
                CalendarEvent.Attendee(name: $0.name == $0.email ? nil : $0.name, email: $0.email, declined: $0.declined ? true : nil, resource: $0.resource ? true : nil)
            },
            meetUrl: findCallLink(links)))
    }

    for (uid, event) in masters {
        func emit(_ instant: Date) {
            if let change = replaced[uid]?[instant], let changed = ICalEvent(change, aliases: aliases) {
                add(changed, start: changed.start.date, end: changed.start.date.addingTimeInterval(changed.duration), isDate: changed.start.isDate, seriesId: uid)
            } else {
                add(event, start: instant, end: instant.addingTimeInterval(event.duration), isDate: event.start.isDate, seriesId: uid)
            }
        }
        let rdates = extraDates(event.component, "RDATE", aliases: aliases)
        guard let rule = event.component.first("RRULE").flatMap({ RecurrenceRule($0.value, aliases: aliases) }) else {
            if rdates.isEmpty {
                add(event, start: event.start.date, end: event.start.date.addingTimeInterval(event.duration), isDate: event.start.isDate, seriesId: nil)
            } else {
                // RDATE without RRULE: DTSTART plus the listed dates.
                ([event.start.date] + rdates).forEach(emit)
            }
            continue
        }
        var excluded = Set(extraDates(event.component, "EXDATE", aliases: aliases))
        // An EXDATE given as a day, on an event that has a time, takes out that day's occurrence: the
        // day in the event's own zone, not whichever moment midnight is on this Mac.
        var excludedDays = Set<String>()
        if !event.start.isDate {
            let days = event.component.all("EXDATE").flatMap { $0.value.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count == 8 && $0.allSatisfy(\.isNumber) }
            excluded.subtract(days.compactMap { parseICalTime($0, tzid: nil, valueType: "DATE", aliases: aliases)?.date })
            excludedDays = Set(days)
        }
        var eventCalendar = Calendar(identifier: .gregorian)
        eventCalendar.timeZone = event.start.zone
        let day = { (instant: Date) -> String in
            let c = eventCalendar.dateComponents([.year, .month, .day], from: instant)
            return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        let instants = Set(rule.occurrences(start: event.start, until: to) + rdates.filter { $0 < to })
        for instant in instants.sorted() where !excluded.contains(instant) && (excludedDays.isEmpty || !excludedDays.contains(day(instant))) {
            emit(instant)
        }
        // An occurrence from beyond the window that was moved into it: its own time wasn't reached above.
        for (instant, change) in replaced[uid] ?? [:] where instant >= to {
            if let changed = ICalEvent(change, aliases: aliases) {
                add(changed, start: changed.start.date, end: changed.start.date.addingTimeInterval(changed.duration), isDate: changed.start.isDate, seriesId: uid)
            }
        }
    }
    // Moved occurrences whose series isn't in the feed stand alone.
    for (uid, byInstant) in replaced where masters[uid] == nil {
        for component in byInstant.values {
            if let event = ICalEvent(component, aliases: aliases) {
                add(event, start: event.start.date, end: event.start.date.addingTimeInterval(event.duration), isDate: event.start.isDate, seriesId: nil)
            }
        }
    }
    return events.sorted { $0.start < $1.start }
}

private func extraDates(_ component: ICalComponent, _ name: String, aliases: [String: TimeZone]) -> [Date] {
    component.all(name).flatMap { p in
        p.value.split(separator: ",").compactMap { parseICalTime(String($0), tzid: p.params["TZID"], valueType: p.params["VALUE"], aliases: aliases)?.date }
    }
}

/// An RRULE, expanded period by period in the event's time zone, so a 10:00 meeting stays at 10:00 across a clock change.
struct RecurrenceRule {
    enum Frequency: String { case DAILY, WEEKLY, MONTHLY, YEARLY }
    var frequency: Frequency
    var interval = 1
    var count: Int?
    var until: Date?
    /// UNTIL given as a day rather than a time: that whole day counts, in the event's own zone.
    var untilDay: DateComponents?
    /// (ordinal or 0, weekday 1 = Sunday … 7 = Saturday)
    var byDay: [(Int, Int)] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var bySetPos: [Int] = []
    var weekStart = 2

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    init?(_ value: String, aliases: [String: TimeZone]) {
        var parts: [String: String] = [:]
        for piece in value.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        guard let freq = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        frequency = freq
        // Kept to what a calendar would write: a feed can say anything, and the sums below mustn't overflow.
        interval = min(1000, max(1, Int(parts["INTERVAL"] ?? "") ?? 1))
        count = parts["COUNT"].flatMap { Int($0) }
        if let value = parts["UNTIL"]?.trimmed, value.count == 8, value.allSatisfy(\.isNumber) {
            untilDay = DateComponents(year: Int(value.prefix(4)), month: Int(value.dropFirst(4).prefix(2)), day: Int(value.suffix(2)), hour: 23, minute: 59, second: 59)
        } else {
            until = parts["UNTIL"].flatMap { parseICalTime($0, tzid: nil, valueType: nil, aliases: aliases)?.date }
        }
        byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { item in
            let s = String(item).uppercased()
            guard let day = Self.weekdays[String(s.suffix(2))], let ordinal = Optional(Int(s.dropLast(2)) ?? 0), (-53...53).contains(ordinal) else { return nil }
            return (ordinal, day)
        }
        byMonthDay = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        byMonth = (parts["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
        bySetPos = (parts["BYSETPOS"] ?? "").split(separator: ",").compactMap { Int($0) }
        weekStart = parts["WKST"].flatMap { Self.weekdays[$0.uppercased()] } ?? 2
    }

    /// Occurrence start instants from DTSTART up to (not including) `limit`. Weekly meetings that began
    /// years ago are a few hundred periods; the cap guards against odd rules.
    func occurrences(start: ICalTime, until limit: Date) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = start.zone
        let until = until ?? untilDay.flatMap { calendar.date(from: $0) }
        calendar.firstWeekday = weekStart
        let wall = calendar.dateComponents([.hour, .minute, .second], from: start.date)
        let startDay = calendar.dateComponents([.year, .month, .day, .weekday], from: start.date)
        var out: [Date] = []
        var emitted = 0

        func at(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var c = DateComponents(year: y, month: m, day: d, hour: wall.hour, minute: wall.minute, second: wall.second)
            c.timeZone = start.zone
            guard let date = calendar.date(from: c), calendar.component(.day, from: date) == d else { return nil }
            return date
        }
        func daysIn(_ y: Int, _ m: Int) -> Int {
            calendar.date(from: DateComponents(year: y, month: m, day: 1)).flatMap { calendar.range(of: .day, in: .month, for: $0) }?.count ?? 0
        }
        /// Days of a month matching BYDAY (with ordinals counted within the month) or BYMONTHDAY.
        func daysOfMonth(_ y: Int, _ m: Int) -> [Int] {
            let count = daysIn(y, m)
            guard count > 0 else { return [] }
            if !byMonthDay.isEmpty {
                return byMonthDay.map { $0 > 0 ? $0 : count + 1 + $0 }.filter { (1...count).contains($0) }
            }
            if !byDay.isEmpty {
                var days: [Int] = []
                for (ordinal, weekday) in byDay {
                    let matching = (1...count).filter { d in
                        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)).map { calendar.component(.weekday, from: $0) } == weekday
                    }
                    if ordinal == 0 { days += matching }
                    else if ordinal > 0, ordinal <= matching.count { days.append(matching[ordinal - 1]) }
                    else if ordinal < 0, -ordinal <= matching.count { days.append(matching[matching.count + ordinal]) }
                }
                return days
            }
            return [startDay.day!]
        }

        var period = 0
        while period < 20_000 {
            var candidates: [Date] = []
            switch frequency {
            case .DAILY:
                guard let day = calendar.date(byAdding: .day, value: period * interval, to: start.date) else { break }
                let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                let dayOK = byDay.isEmpty || byDay.contains { $0.1 == c.weekday }
                let monthOK = byMonth.isEmpty || byMonth.contains(c.month!)
                let monthDayOK = byMonthDay.isEmpty || byMonthDay.contains(c.day!)
                if dayOK && monthOK && monthDayOK, let d = at(c.year!, c.month!, c.day!) { candidates = [d] }
            case .WEEKLY:
                guard let anchor = calendar.date(byAdding: .weekOfYear, value: period * interval, to: start.date),
                      let week = calendar.dateInterval(of: .weekOfYear, for: anchor) else { break }
                let weekdays = byDay.isEmpty ? [startDay.weekday!] : byDay.map(\.1)
                for offset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                    if weekdays.contains(c.weekday!), byMonth.isEmpty || byMonth.contains(c.month!), let d = at(c.year!, c.month!, c.day!) {
                        candidates.append(d)
                    }
                }
            case .MONTHLY:
                let total = (startDay.year! * 12 + startDay.month! - 1) + period * interval
                let (y, m) = (total / 12, total % 12 + 1)
                if byMonth.isEmpty || byMonth.contains(m) { candidates = daysOfMonth(y, m).compactMap { at(y, m, $0) } }
            case .YEARLY:
                let y = startDay.year! + period * interval
                for m in byMonth.isEmpty ? [startDay.month!] : byMonth { candidates += daysOfMonth(y, m).compactMap { at(y, m, $0) } }
            }
            candidates = Array(Set(candidates)).sorted()
            if !bySetPos.isEmpty {
                candidates = bySetPos.compactMap { pos in
                    let i = pos > 0 ? pos - 1 : candidates.count + pos
                    return candidates.indices.contains(i) ? candidates[i] : nil
                }.sorted()
            }
            for candidate in candidates where candidate >= start.date {
                if let until, candidate > until { return out }
                if let count, emitted >= count { return out }
                if candidate >= limit { return out }
                emitted += 1
                out.append(candidate)
            }
            // Past the window with nothing left to emit in it.
            if let first = candidates.first, first >= limit { return out }
            period += 1
        }
        return out
    }
}

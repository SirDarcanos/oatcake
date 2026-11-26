// A feed's events as the occurrences in a window of time: recurring events expanded (RRULE, EXDATE,
// RDATE, and moved or cancelled occurrences), in each event's own time zone.

import CryptoKit
import Foundation

struct ICalEvent {
    let component: ICalComponent
    let uid: String
    let start: ICalTime
    let duration: TimeInterval
    /// An all-day event's length in days: each occurrence ends at midnight, also across a clock
    /// change, where a length in seconds would make the day after it 23 or 25 hours long.
    let days: Int?

    init?(_ component: ICalComponent, aliases: [String: TimeZone]) {
        guard let dtstart = component.first("DTSTART"),
              let start = parseICalTime(dtstart.value, tzid: dtstart.params["TZID"], valueType: dtstart.params["VALUE"], aliases: aliases) else { return nil }
        self.component = component
        uid = eventUID(component)
        self.start = start
        if let dtend = component.first("DTEND"),
           let end = parseICalTime(dtend.value, tzid: dtend.params["TZID"], valueType: dtend.params["VALUE"], aliases: aliases) {
            duration = end.date.timeIntervalSince(start.date)
        } else if let d = component.first("DURATION").flatMap({ parseDuration($0.value) }) {
            duration = d
        } else {
            duration = start.isDate ? 86_400 : 0
        }
        days = start.isDate ? Int((duration / 86_400).rounded()) : nil
    }

    var summary: String { component.first("SUMMARY").map { unescapeText($0.value) } ?? "" }

    /// When an occurrence that starts at `start` ends.
    func end(from start: Date) -> Date {
        guard let days, let end = gregorian.date(byAdding: .day, value: days, to: start) else { return start.addingTimeInterval(duration) }
        return end
    }
}

/**
 * An event's UID, or for one without (which RFC 5545 doesn't allow, but a feed can do anything) one
 * made from its start and title: the same at every fetch, so it keeps its ID (and what's kept by it,
 * such as prep notes and ignoring it), and two such events don't take each other's place.
 */
func eventUID(_ component: ICalComponent) -> String {
    if let uid = component.first("UID")?.value, !uid.isEmpty { return uid }
    let made = [component.first("DTSTART")?.value, component.first("SUMMARY")?.value].map { $0 ?? "" }.joined(separator: "\n")
    return "no-uid-" + SHA256.hash(data: Data(made.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
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
    // A change made to one occurrence and every one after it (RANGE=THISANDFUTURE), by the instant it starts from.
    var onwards: [String: [(from: Date, component: ICalComponent)]] = [:]
    for component in calendar.components("VEVENT") {
        let uid = eventUID(component)
        if let rid = component.first("RECURRENCE-ID") {
            // One whose occurrence can't be read is left out: taken for the series, it would replace it.
            guard let instant = parseICalTime(rid.value, tzid: rid.params["TZID"], valueType: rid.params["VALUE"], aliases: aliases) else { continue }
            replaced[uid, default: [:]][instant.date] = component
            if (rid.params["RANGE"] ?? "").uppercased() == "THISANDFUTURE" { onwards[uid, default: []].append((instant.date, component)) }
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
        // The latest change made from an occurrence onwards comes first.
        let fromThisOn = (onwards[uid] ?? []).sorted { $0.from > $1.from }
        func emit(_ instant: Date, seriesId: String? = uid) {
            if let change = replaced[uid]?[instant], let changed = ICalEvent(change, aliases: aliases) {
                add(changed, start: changed.start.date, end: changed.end(from: changed.start.date), isDate: changed.start.isDate, seriesId: seriesId)
            } else if let onward = fromThisOn.first(where: { $0.from < instant }), let changed = ICalEvent(onward.component, aliases: aliases) {
                // Moved by as much as the occurrence it was made on, and as it is now in every other way.
                let start = instant.addingTimeInterval(changed.start.date.timeIntervalSince(onward.from))
                add(changed, start: start, end: changed.end(from: start), isDate: changed.start.isDate, seriesId: seriesId)
            } else {
                add(event, start: instant, end: event.end(from: instant), isDate: event.start.isDate, seriesId: seriesId)
            }
        }
        let rdates = extraDates(event.component, "RDATE", aliases: aliases)
        guard let rule = event.component.first("RRULE").flatMap({ RecurrenceRule($0.value, aliases: aliases) }) else {
            if rdates.isEmpty {
                // An event that doesn't recur can still come with a changed copy of itself.
                emit(event.start.date, seriesId: nil)
            } else {
                // RDATE without RRULE: DTSTART plus the listed dates.
                ([event.start.date] + rdates).forEach { emit($0) }
            }
            continue
        }
        var excluded = Set(extraDates(event.component, "EXDATE", aliases: aliases))
        // An EXDATE given as a day, on an event that has a time, takes out that day's occurrence: the
        // day in the event's own zone, not whichever moment midnight is on this Mac. So does one given
        // as midnight on the day, which is how some calendars write a day taken out.
        var excludedDays = Set<String>()
        if !event.start.isDate {
            let values = event.component.all("EXDATE").flatMap { $0.value.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
            let days = values.filter { $0.count == 8 && $0.allSatisfy(\.isNumber) }
            excluded.subtract(days.compactMap { parseICalTime($0, tzid: nil, valueType: "DATE", aliases: aliases)?.date })
            let midnights = values.filter { $0.count == 15 && $0.hasSuffix("T000000") && $0.prefix(8).allSatisfy(\.isNumber) }.map { String($0.prefix(8)) }
            excludedDays = Set(days + midnights)
        }
        var eventCalendar = Calendar(identifier: .gregorian)
        eventCalendar.timeZone = event.start.zone
        let day = { (instant: Date) -> String in
            let c = eventCalendar.dateComponents([.year, .month, .day], from: instant)
            return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        // From early enough that one still going at the window's start is included.
        let instants = Set(rule.occurrences(start: event.start, from: from.addingTimeInterval(-max(0, event.duration)), until: to) + rdates.filter { $0 < to })
        for instant in instants.sorted() where !excluded.contains(instant) && (excludedDays.isEmpty || !excludedDays.contains(day(instant))) {
            emit(instant)
        }
        // An occurrence from beyond the window that was moved into it: its own time wasn't reached above.
        for (instant, change) in replaced[uid] ?? [:] where instant >= to {
            if let changed = ICalEvent(change, aliases: aliases) {
                add(changed, start: changed.start.date, end: changed.end(from: changed.start.date), isDate: changed.start.isDate, seriesId: uid)
            }
        }
    }
    // Moved occurrences whose series isn't in the feed stand alone.
    for (uid, byInstant) in replaced where masters[uid] == nil {
        for component in byInstant.values {
            if let event = ICalEvent(component, aliases: aliases) {
                add(event, start: event.start.date, end: event.end(from: event.start.date), isDate: event.start.isDate, seriesId: nil)
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
    enum Frequency: String { case SECONDLY, MINUTELY, HOURLY, DAILY, WEEKLY, MONTHLY, YEARLY }
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
    /// years ago are a few hundred periods; the cap guards against odd rules. An hourly or finer rule
    /// with no COUNT starts at the last of its steps at or before `from` instead: from DTSTART, one that
    /// began long ago (minutely, a fortnight; hourly, a couple of years) would reach the cap before the window.
    func occurrences(start: ICalTime, from: Date = .distantPast, until limit: Date) -> [Date] {
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
        func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int? {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)).map { calendar.component(.weekday, from: $0) }
        }
        /// Of the days that are `ordinal`'s weekday, the one it counts to (2: the second; -1: the last), or all of them for 0.
        func picked<Day>(_ matching: [Day], _ ordinal: Int) -> [Day] {
            if ordinal == 0 { return matching }
            if ordinal > 0, ordinal <= matching.count { return [matching[ordinal - 1]] }
            if ordinal < 0, -ordinal <= matching.count { return [matching[matching.count + ordinal]] }
            return []
        }
        /// Days of a month matching BYDAY (with ordinals counted within the month) or BYMONTHDAY.
        func daysOfMonth(_ y: Int, _ m: Int) -> [Int] {
            let count = daysIn(y, m)
            guard count > 0 else { return [] }
            if !byMonthDay.isEmpty {
                return byMonthDay.map { $0 > 0 ? $0 : count + 1 + $0 }.filter { (1...count).contains($0) }
            }
            if !byDay.isEmpty {
                return byDay.flatMap { ordinal, day in picked((1...count).filter { weekday(y, m, $0) == day }, ordinal) }
            }
            return [startDay.day!]
        }
        /// For a yearly rule with BYDAY and no months: the days of the year it names, its ordinals
        /// counted within the year (BYDAY=20MO is the twentieth Monday).
        func daysOfYear(_ y: Int) -> [Date] {
            let all = (1...12).flatMap { m in (1...max(1, daysIn(y, m))).map { (m, $0) } }
            return byDay.flatMap { ordinal, day in picked(all.filter { weekday(y, $0.0, $0.1) == day }, ordinal) }.compactMap { at(y, $0.0, $0.1) }
        }

        var period = 0
        let step: Double? = switch frequency {
        case .HOURLY: 3600
        case .MINUTELY: 60
        case .SECONDLY: 1
        default: nil
        }
        // Each step is a whole number of hours, minutes or seconds from DTSTART, so the one to start at
        // is a division; the BY filters are applied to each step as before.
        if let step, count == nil, from > start.date {
            period = Int(from.timeIntervalSince(start.date) / (step * Double(interval)))
        }
        let firstPeriod = period
        while period - firstPeriod < 20_000 {
            var candidates: [Date] = []
            switch frequency {
            case .HOURLY, .MINUTELY, .SECONDLY:
                let unit: Calendar.Component = frequency == .HOURLY ? .hour : frequency == .MINUTELY ? .minute : .second
                guard let time = calendar.date(byAdding: unit, value: period * interval, to: start.date) else { break }
                if time >= limit { return out }
                let c = calendar.dateComponents([.month, .day, .weekday], from: time)
                let dayOK = byDay.isEmpty || byDay.contains { $0.1 == c.weekday }
                let monthOK = byMonth.isEmpty || byMonth.contains(c.month!)
                let monthDayOK = byMonthDay.isEmpty || byMonthDay.contains(c.day!)
                if dayOK && monthOK && monthDayOK { candidates = [time] }
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
                // A rule that matches no day (BYDAY=6MO) has nothing left once its months are past the window.
                if let first = calendar.date(from: DateComponents(year: y, month: m, day: 1)), first >= limit { return out }
                if byMonth.isEmpty || byMonth.contains(m) { candidates = daysOfMonth(y, m).compactMap { at(y, m, $0) } }
            case .YEARLY:
                let y = startDay.year! + period * interval
                if let first = calendar.date(from: DateComponents(year: y, month: 1, day: 1)), first >= limit { return out }
                if byMonth.isEmpty && byMonthDay.isEmpty && !byDay.isEmpty {
                    candidates = daysOfYear(y)
                } else {
                    for m in byMonth.isEmpty ? [startDay.month!] : byMonth { candidates += daysOfMonth(y, m).compactMap { at(y, m, $0) } }
                }
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

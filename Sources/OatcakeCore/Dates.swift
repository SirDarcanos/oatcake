// Dates, times and lengths of time as the windows show them: in the Mac's region (the day before the
// month or after it, its names for them) and on its 12- or 24-hour clock, but always on the Gregorian
// calendar, as folder names and to-dos are. What's written into files (folder names, todo.md) keeps
// formats of its own. Also when a meeting happened, for listing meetings newest first.

import Foundation

/// What every format here starts from. `locale` is the Mac's region and clock unless a test says otherwise.
private func style(_ locale: Locale) -> Date.FormatStyle {
    Date.FormatStyle(locale: locale, calendar: gregorian, timeZone: gregorian.timeZone)
}

private func sameYear(_ a: Date, _ b: Date) -> Bool {
    gregorian.component(.year, from: a) == gregorian.component(.year, from: b)
}

/// "Thursday 29 October 2026" ("Thursday, October 29, 2026" in the US): a meeting's own date, over it.
public func longDay(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
    date.formatted(style(locale).weekday(.wide).day().month(.wide).year())
}

/// "Thu 29 Oct", and the year when it isn't this one: a meeting in the list, a to-do's due date.
public func shortDay(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
    let day = style(locale).weekday(.abbreviated).day().month(.abbreviated)
    return date.formatted(sameYear(date, now) ? day : day.year())
}

/// "29 Oct", and the year when it isn't this one: a day beside a name.
public func compactDate(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
    let day = style(locale).day().month(.abbreviated)
    return date.formatted(sameYear(date, now) ? day : day.year())
}

/// "16:30", or "4:30 pm" on a 12-hour clock.
public func timeOfDay(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
    date.formatted(style(locale).hour().minute())
}

/// "Thu 16:30": a call later this week.
public func dayAndTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
    date.formatted(style(locale).weekday(.abbreviated).hour().minute())
}

/// "4 Nov at 21:10": tells two recordings of the same call apart.
public func dateAndTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
    date.formatted(style(locale).day().month(.abbreviated).hour().minute())
}

/// "Thursday", or "Thu".
public func weekdayName(_ date: Date, short: Bool = false, locale: Locale = .autoupdatingCurrent) -> String {
    date.formatted(style(locale).weekday(short ? .abbreviated : .wide))
}

/// A length of time as whole seconds under a minute, and in whole minutes from then on: rounded down,
/// so "silent for 2 minutes" is never said after 90 seconds.
private func parts(_ seconds: Double) -> (hours: Int, minutes: Int, seconds: Int) {
    let seconds = max(0, seconds)
    guard seconds >= 60 else { return (0, 0, Int(seconds)) }
    let minutes = Int(seconds / 60)
    return (minutes / 60, minutes % 60, 0)
}

/// "45s", "12m", "1h 5m": a length of time where there's little room (the menu bar, a countdown).
public func shortDuration(_ seconds: Double) -> String {
    let (h, m, s) = parts(seconds)
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    return m > 0 ? "\(m)m" : "\(s)s"
}

/// "45 seconds", "12 minutes", "1 hour 5 minutes": a length of time in a sentence or beside a date.
public func longDuration(_ seconds: Double) -> String {
    let (h, m, s) = parts(seconds)
    func count(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
    if h > 0 { return m > 0 ? "\(count(h, "hour")) \(count(m, "minute"))" : count(h, "hour") }
    return m > 0 ? count(m, "minute") : count(s, "second")
}

/// When a meeting happened: meeting.json's start, or else the "2026-10-02 1400 Title" folder name's.
public func meetingDate(_ node: TreeNode) -> Date? {
    if let d = node.startedAt { return d }
    let digits = node.name.prefix(15)
    guard digits.range(of: #"^\d{4}-\d{2}-\d{2} \d{4}$"#, options: .regularExpression) != nil else { return nil }
    let n = { (from: Int, len: Int) in Int(digits.dropFirst(from).prefix(len)) ?? 0 }
    return gregorian.date(from: DateComponents(year: n(0, 4), month: n(5, 2), day: n(8, 2), hour: n(11, 2), minute: n(13, 2)))
}

/// The meeting list's order: newest first, and by folder name for two at the same time (or with no date).
public func newestFirst(_ a: TreeNode, _ b: TreeNode) -> Bool {
    let da = meetingDate(a) ?? .distantPast, db = meetingDate(b) ?? .distantPast
    return da != db ? da > db : a.name > b.name
}

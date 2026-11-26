// Reading iCalendar text (RFC 5545): its components and content lines, TEXT values, date-times
// and durations, and the time zones they're written in.

import Foundation

/// One content line: NAME;PARAM=value:VALUE.
struct ICalProperty {
    var name: String
    var params: [String: String]
    var value: String
}

final class ICalComponent {
    let name: String
    var properties: [ICalProperty] = []
    var children: [ICalComponent] = []
    var closed = false
    init(name: String) { self.name = name }

    func first(_ name: String) -> ICalProperty? { properties.first { $0.name == name } }
    func all(_ name: String) -> [ICalProperty] { properties.filter { $0.name == name } }
    func components(_ name: String) -> [ICalComponent] { children.filter { $0.name == name } }
}

func parseICal(_ text: String) -> ICalComponent {
    // A byte-order mark in front would hide the first BEGIN.
    let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    // Unfold: a line starting with a space or tab continues the one before.
    var lines: [String] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
        if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
            lines[lines.count - 1] += raw.dropFirst()
        } else if !raw.isEmpty {
            lines.append(raw)
        }
    }
    let root = ICalComponent(name: "ROOT")
    var stack = [root]
    for line in lines {
        guard let property = parseContentLine(line) else { continue }
        if property.name == "BEGIN" {
            let child = ICalComponent(name: property.value.uppercased())
            stack.last!.children.append(child)
            stack.append(child)
        } else if property.name == "END" {
            // Closes the component it names. One left open inside it (an alarm with no END, say) is
            // closed with it, rather than keeping everything after it from being read.
            let name = property.value.uppercased()
            if let index = stack.lastIndex(where: { $0.name == name }), index > 0 {
                stack[index].closed = true
                stack.removeSubrange(index...)
            }
        } else {
            stack.last!.properties.append(property)
        }
    }
    return root.children.first { $0.name == "VCALENDAR" } ?? root
}

private func parseContentLine(_ line: String) -> ICalProperty? {
    // The value starts at the first colon outside a quoted parameter value.
    var inQuotes = false
    var colon: String.Index?
    for i in line.indices {
        let c = line[i]
        if c == "\"" { inQuotes.toggle() }
        if c == ":" && !inQuotes { colon = i; break }
    }
    guard let colon else { return nil }
    let head = line[..<colon]
    let value = String(line[line.index(after: colon)...])
    var parts: [String] = []
    var current = ""
    inQuotes = false
    for c in head {
        if c == "\"" { inQuotes.toggle(); continue }
        if c == ";" && !inQuotes { parts.append(current); current = ""; continue }
        current.append(c)
    }
    parts.append(current)
    var params: [String: String] = [:]
    for p in parts.dropFirst() {
        guard let eq = p.firstIndex(of: "=") else { continue }
        params[p[..<eq].uppercased()] = String(p[p.index(after: eq)...])
    }
    return ICalProperty(name: parts[0].uppercased(), params: params, value: value)
}

/// TEXT values escape commas, semicolons, backslashes and newlines.
func unescapeText(_ value: String) -> String {
    var out = ""
    var escaping = false
    for c in value {
        if escaping {
            out.append(c == "n" || c == "N" ? "\n" : c)
            escaping = false
        } else if c == "\\" {
            escaping = true
        } else {
            out.append(c)
        }
    }
    return out
}

/// A DTSTART-style time: an instant, whether it's a whole day, and the zone its wall-clock time is in.
struct ICalTime {
    var date: Date
    var isDate: Bool
    var zone: TimeZone
}

func timeZone(_ tzid: String?, aliases: [String: TimeZone]) -> TimeZone {
    guard let tzid else { return .current }
    let clean = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: #"^/"#, with: "", options: .regularExpression)
    return TimeZone(identifier: clean) ?? aliases[tzid] ?? .current
}

/// "+0100", "-0500" or "+053000" → seconds east of UTC.
private func utcOffset(_ value: String) -> Int? {
    let v = value.trimmed
    guard let sign = v.first, sign == "+" || sign == "-", v.count >= 5,
          let hours = Int(v.dropFirst().prefix(2)), let minutes = Int(v.dropFirst(3).prefix(2)) else { return nil }
    return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
}

/**
 * A zone for a VTIMEZONE whose name macOS doesn't know (Outlook's "GMT Standard Time"), from the
 * offsets it gives. With no daylight time, that fixed offset. With it, a zone macOS knows that is at
 * the same offset in the middle of every month the rules leave no doubt about (this Mac's own, when
 * it is): which of the zones that keep those hours hardly matters, since they agree all year but
 * for the weeks the clocks change in.
 */
func zoneFromRules(_ zone: ICalComponent, now: Date = Date()) -> TimeZone? {
    func block(_ name: String) -> ICalComponent? { zone.components(name).first { $0.first("RRULE") != nil } ?? zone.components(name).first }
    func offset(_ block: ICalComponent?) -> Int? { block?.first("TZOFFSETTO").flatMap { utcOffset($0.value) } }
    /// The month a block's time starts in each year: its rule's BYMONTH, or its DTSTART's month.
    func month(_ block: ICalComponent?) -> Int? {
        if let rule = block?.first("RRULE")?.value, let found = firstMatch(try! NSRegularExpression(pattern: #"BYMONTH=(\d{1,2})"#), rule)?[1] ?? nil { return Int(found) }
        return (block?.first("DTSTART")?.value).flatMap { $0.count >= 6 ? Int($0.dropFirst(4).prefix(2)) : nil }
    }
    let standard = block("STANDARD"), daylight = block("DAYLIGHT")
    guard let winter = offset(standard) ?? offset(daylight) else { return nil }
    guard let summer = offset(daylight), offset(standard) != nil, let starts = month(daylight), let ends = month(standard), starts != ends else {
        return TimeZone(secondsFromGMT: winter)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let year = calendar.component(.year, from: now)
    // The months the clocks change in are left out: which side of the change their middle falls on isn't said here.
    let expected = (1...12).filter { $0 != starts && $0 != ends }.compactMap { m -> (Date, Int)? in
        let inDaylight = starts < ends ? (m > starts && m < ends) : (m > starts || m < ends)
        return calendar.date(from: DateComponents(year: year, month: m, day: 15, hour: 12)).map { ($0, inDaylight ? summer : winter) }
    }
    let keepsThoseHours = { (tz: TimeZone) in expected.allSatisfy { tz.secondsFromGMT(for: $0.0) == $0.1 } }
    if keepsThoseHours(.current) { return .current }
    return TimeZone.knownTimeZoneIdentifiers.sorted().lazy.compactMap(TimeZone.init(identifier:)).first(where: keepsThoseHours)
}

/// Parses one date or date-time value ("20261105", "20261105T140000", "20261105T140000Z").
func parseICalTime(_ value: String, tzid: String?, valueType: String?, aliases: [String: TimeZone]) -> ICalTime? {
    let v = value.trimmed
    var calendar = Calendar(identifier: .gregorian)
    let digits = v.filter(\.isNumber)
    if valueType?.uppercased() == "DATE" || (v.count == 8 && digits.count == 8) {
        // Whole days have no zone: they're days in whichever zone you're in.
        calendar.timeZone = .current
        guard digits.count >= 8, let y = Int(digits.prefix(4)), let m = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.dropFirst(6).prefix(2)),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        return ICalTime(date: date, isDate: true, zone: .current)
    }
    guard digits.count >= 14 else { return nil }
    let utc = v.hasSuffix("Z")
    let zone = utc ? TimeZone(identifier: "UTC")! : timeZone(tzid, aliases: aliases)
    calendar.timeZone = zone
    let n = { (from: Int, len: Int) in Int(digits.dropFirst(from).prefix(len)) ?? 0 }
    guard let date = calendar.date(from: DateComponents(year: n(0, 4), month: n(4, 2), day: n(6, 2), hour: n(8, 2), minute: n(10, 2), second: n(12, 2))) else { return nil }
    return ICalTime(date: date, isDate: false, zone: zone)
}

/// "PT1H30M", "P1D", "-PT15M" → seconds.
func parseDuration(_ value: String) -> TimeInterval? {
    let regex = try! NSRegularExpression(pattern: #"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#)
    guard let g = firstMatch(regex, value.trimmed) else { return nil }
    let num = { (i: Int) in Double(g[i] ?? "") ?? 0 }
    let total = num(2) * 604_800 + num(3) * 86_400 + num(4) * 3600 + num(5) * 60 + num(6)
    return g[1] == "-" ? -total : total
}

// Dates, times and people, formatted the way the design shows them.

import OatcakeCore
import SwiftUI

private let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

func ordinal(_ d: Int) -> String {
    let suffix = (11...13).contains(d % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][d % 10] ?? "th"
    return "\(d)\(suffix)"
}

private var cal: Calendar { gregorian }

/// "October 29th, 2026"
func longDate(_ d: Date) -> String { "\(months[cal.component(.month, from: d) - 1]) \(ordinal(cal.component(.day, from: d))), \(cal.component(.year, from: d))" }
/// "October 29th"
func shortDate(_ d: Date) -> String { "\(months[cal.component(.month, from: d) - 1]) \(ordinal(cal.component(.day, from: d)))" }
/// "Thursday"
func weekday(_ d: Date) -> String { weekdays[cal.component(.weekday, from: d) - 1] }
/// "Thu"
func shortWeekday(_ d: Date) -> String { String(weekday(d).prefix(3)) }
/// "Oct"
func shortMonth(_ d: Date) -> String { String(months[cal.component(.month, from: d) - 1].prefix(3)) }
/// "Oct 29", or "Oct 29, 2025" in another year: a day in a list or beside a name.
func compactDate(_ d: Date, now: Date = Date()) -> String {
    let day = "\(shortMonth(d)) \(cal.component(.day, from: d))"
    return cal.component(.year, from: d) == cal.component(.year, from: now) ? day : "\(day), \(cal.component(.year, from: d))"
}
/// "16:30"
func hhmm(_ d: Date) -> String { String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d)) }

/// "32 min", or "under a minute".
func minutes(_ seconds: Double) -> String { seconds < 60 ? "under a minute" : "\(Int((seconds / 60).rounded())) min" }

/// The meeting's folder path for display: "Team 51 › Leads sync". "" is the top level.
func folderPath(_ rel: String) -> String { rel.isEmpty ? "Meetings" : rel.split(separator: "/").joined(separator: " › ") }
func baseName(_ rel: String) -> String { rel.split(separator: "/").last.map(String.init) ?? rel }
func parentOf(_ rel: String) -> String { rel.split(separator: "/").dropLast().joined(separator: "/") }

/// The folder's name (or whole path) says the same as the title, e.g. "Team 51/Leads sync" for "Team 51 – Leads sync".
func sameAsFolder(_ title: String, _ folder: String) -> Bool {
    !folder.isEmpty && !loose(title).isEmpty && (loose(title) == loose(baseName(folder)) || loose(title) == loose(folder))
}
/// The path above a title, without its last part when that only repeats the title.
func pathAbove(_ folder: String, _ title: String) -> String { folderPath(sameAsFolder(title, folder) ? parentOf(folder) : folder) }

/// Is this owner you? "John" counts for "John Smith".
func isMe(_ owner: String?, _ myName: String) -> Bool {
    guard let owner = owner?.trimmed.lowercased(), !owner.isEmpty, !myName.isEmpty else { return false }
    return [myName.lowercased(), (myName.split(separator: " ").first.map(String.init) ?? myName).lowercased()].contains(owner)
}
/// An owner as shown: "You" for you.
func ownerLabel(_ owner: String, _ myName: String) -> String { isMe(owner, myName) ? "You" : owner }

/// Said when a to-do that was ticked turns out to be worded differently in its file now (it was
/// edited there since this was read): nothing is ticked, and what's shown is read again.
let todoChangedMessage = "That to-do has changed in its meeting since this list was read, so it wasn’t ticked. The list has been read again."


/// When a meeting happened: meeting.json, or the "2026-10-02 1400 Title" folder name.
func meetingDate(_ node: TreeNode) -> Date? {
    if let d = node.startedAt { return d }
    let digits = node.name.prefix(15)
    guard digits.range(of: #"^\d{4}-\d{2}-\d{2} \d{4}$"#, options: .regularExpression) != nil else { return nil }
    let n = { (from: Int, len: Int) in Int(digits.dropFirst(from).prefix(len)) ?? 0 }
    return cal.date(from: DateComponents(year: n(0, 4), month: n(5, 2), day: n(8, 2), hour: n(11, 2), minute: n(13, 2)))
}

/// The title to show: meeting.json's, or the folder name without its date.
func meetingTitle(_ node: TreeNode) -> String {
    if let t = node.title, !t.isEmpty { return t }
    return node.name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, with: "", options: .regularExpression)
}

private func newestFirst(_ a: TreeNode, _ b: TreeNode) -> Bool {
    let da = meetingDate(a) ?? .distantPast, db = meetingDate(b) ?? .distantPast
    return da != db ? da > db : a.name > b.name
}

/// What the middle column lists: a folder's own meetings, or every meeting for the top level.
func listedIn(_ folder: TreeNode?) -> [TreeNode] {
    guard let folder else { return [] }
    return (folder.path.isEmpty ? folder.allMeetings : folder.meetings).sorted(by: newestFirst)
}

// MARK: - People

/// "Jane Doe" from an attendee, or from "jane.doe@…" when the invite has no name.
func attendeeName(_ a: CalendarEvent.Attendee) -> String {
    if let name = a.name, !name.isEmpty { return name }
    return (a.email.split(separator: "@").first.map(String.init) ?? a.email)
        .split(whereSeparator: { "._-".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

/// The other people coming to an event: not you, not anyone who declined, not rooms, and each name once.
func otherAttendees(_ event: CalendarEvent, myName: String) -> [CalendarEvent.Attendee] {
    let me = myName.lowercased()
    let first = me.split(separator: " ").first.map(String.init) ?? me
    var seen = Set<String>()
    return event.attendees.filter {
        let n = attendeeName($0).lowercased()
        return $0.declined != true && $0.resource != true && n != me && n != first && seen.insert(n).inserted
    }
}

/// Labels that aren't a person: their avatars are grey.
private let notAPerson = #"^(Voice \d+|Several people|Microphone|System audio|Call audio|Unknown)$"#
private let hues = SwatchColour.allCases.map(\.hue)
private let colorsKey = "personColors"
/// Colours you chose, by full name: apart from the first-name colours above, which a one-word name
/// ("Jane") would otherwise share with everyone of that first name.
private let chosenColorsKey = "personChosenColors"
/// Bumped when you choose someone's colour, so avatars already on screen take it straight away.
let colorsChangedKey = "personColorsChanged"

/// The first-name key a colour is remembered under, and the full name's, for a colour you chose.
private func firstNameKey(_ name: String) -> String { (name.trimmed.split(separator: " ").first.map(String.init) ?? name).lowercased() }
private func fullNameKey(_ name: String) -> String { name.trimmed.lowercased() }

extension SwatchColour {
    var swatch: Color { oklch(0.55, 0.15, hue) }
}

/// The colour you chose for someone in Settings › People (an index into the palette), if you did.
func chosenColor(_ name: String) -> Int? {
    let chosen = (UserDefaults.standard.dictionary(forKey: chosenColorsKey) as? [String: Int]) ?? [:]
    return chosen[fullNameKey(name)].flatMap { hues.indices.contains($0) ? $0 : nil }
}

/// Chooses someone's colour (nil: back to the one Oatcake gave them). It's kept under their full
/// name, ahead of the one their first name has, so two people called Jane can have different colours.
func chooseColor(_ index: Int?, for name: String) {
    var chosen = (UserDefaults.standard.dictionary(forKey: chosenColorsKey) as? [String: Int]) ?? [:]
    chosen[fullNameKey(name)] = index
    UserDefaults.standard.set(chosen, forKey: chosenColorsKey)
    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: colorsChangedKey) + 1, forKey: colorsChangedKey)
}

/// A chosen colour goes with the name when someone is renamed or merged into someone else in Settings ›
/// People, unless the name they now go by has one. The old name keeps it too: meetings already saved
/// still use that name.
func carryChosenColor(from old: String, to new: String) {
    guard let index = chosenColor(old), chosenColor(new) == nil else { return }
    chooseColor(index, for: new)
}

/**
 * Each person keeps one colour everywhere and for good: the first time a name is seen it takes the
 * palette's least-used hue (in the order above, which spreads early picks around the wheel), and that
 * choice is remembered. Keyed by first name, so "Jane" and "Jane Doe" match, unless you've chosen a
 * colour for the full name.
 */
private func hueFor(_ name: String, remember: Bool) -> Double {
    var all = (UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: Int]) ?? [:]
    if let chosen = chosenColor(name) { return hues[chosen] }
    let key = firstNameKey(name)
    if let i = all[key], hues.indices.contains(i) { return hues[i] }
    let uses = hues.indices.map { i in all.values.filter { $0 == i }.count }
    let index = uses.firstIndex(of: uses.min()!)!
    // A name typed but not yet saved (in review) gets a colour without claiming one.
    if remember {
        all[key] = index
        UserDefaults.standard.set(all, forKey: colorsKey)
    }
    return hues[index]
}

/**
 * Colours for the names on a Who's who screen, where nothing is claimed until the meeting is saved:
 * someone seen before keeps their colour, and each new name takes the next free one, in the order
 * saving will then claim them. Without this, every new name would show the same least-used colour.
 */
func provisionalColors(_ names: [String]) -> [String: Color] {
    provisionalHues(names).mapValues { oklch(0.55, 0.15, $0) }
}

/// The same colours for those names written as text (the review transcript's speaker names), where
/// the avatar's own shade is too close to the window behind it to read comfortably.
func provisionalNameColors(_ names: [String]) -> [String: Color] {
    provisionalHues(names).mapValues(nameColor)
}

private func provisionalHues(_ names: [String]) -> [String: Double] {
    let all = (UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: Int]) ?? [:]
    var uses = hues.indices.map { i in all.values.filter { $0 == i }.count }
    var taken: [String: Int] = [:]
    var out: [String: Double] = [:]
    for name in names where !name.trimmed.isEmpty && name.range(of: notAPerson, options: .regularExpression) == nil {
        let key = firstNameKey(name)
        let index: Int
        if let known = chosenColor(name) ?? all[key] ?? taken[key], hues.indices.contains(known) {
            index = known
        } else {
            index = uses.firstIndex(of: uses.min()!)!
            uses[index] += 1
            taken[key] = index
        }
        out[name] = hues[index]
    }
    return out
}

/**
 * A person's hue as a colour for their name in text: darker than the avatar's on a light window and
 * lighter on a dark one, so that every hue in the palette stands at least 4.5:1 against the window
 * (worked out for each of the twelve against the window's own background, light and dark).
 */
private func nameColor(_ hue: Double) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (r, g, b) = oklchRGB(dark ? 0.78 : 0.47, dark ? 0.12 : 0.15, hue)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    })
}

struct Person {
    var initial: String
    var color: Color
}

/// A person's avatar colour and initial: the same colour on every screen.
func person(_ name: String, remember: Bool = true) -> Person {
    let clean = name.replacingOccurrences(of: "^Voice ", with: "", options: .regularExpression)
    // Two letters for a full name ("JD" for Jane Doe), so people who share a first name, and so a
    // colour, can still be told apart.
    // Not what's in brackets ("Jane Doe (Acme)") or a suffix ("Jane Doe Jr.").
    let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
    let words = clean.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        .split(whereSeparator: \.isWhitespace)
        .filter { !suffixes.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        .compactMap { $0.first { $0.isLetter || $0.isNumber } }
    let initial = (words.count > 1 ? String([words[0], words[words.count - 1]]) : words.first.map(String.init) ?? "?").uppercased()
    if name.trimmed.isEmpty || name.range(of: notAPerson, options: .regularExpression) != nil {
        return Person(initial: name.hasPrefix("Voice") ? String(clean.prefix(1)) : initial, color: Color(nsColor: .systemGray))
    }
    return Person(initial: initial, color: oklch(0.55, 0.15, hueFor(name, remember: remember)))
}

/// The design's oklch(L C h) colours, in sRGB.
func oklch(_ l: Double, _ c: Double, _ h: Double) -> Color {
    let (r, g, b) = oklchRGB(l, c, h)
    return Color(.sRGB, red: r, green: g, blue: b)
}

private func oklchRGB(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
    let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
    let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
    let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
    func gamma(_ x: Double) -> Double {
        let v = max(0, min(1, x))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    return (gamma(r), gamma(g), gamma(bl))
}

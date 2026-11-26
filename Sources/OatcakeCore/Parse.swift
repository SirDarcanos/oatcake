// Reading the meeting files for the rendered views. Each format Oatcake has written, plus Granola's
// imports, is understood.

import Foundation

/// "0:20" → "00:20", so every timestamp reads the same way.
public func padStamp(_ stamp: String) -> String {
    stamp.range(of: #"^\d:\d\d$"#, options: .regularExpression) != nil ? "0" + stamp : stamp
}

/// "12:34" or "1:02:03" → seconds.
public func seconds(_ stamp: String) -> Double {
    let p = stamp.split(separator: ":").map { Double($0) ?? 0 }
    return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p.count == 2 ? p[0] * 60 + p[1] : 0
}

/// "03:09", or "1:02:09" past an hour.
public func clock(_ seconds: Double) -> String {
    // A time that isn't one (from a damaged import) reads as the start, and none runs past 99 hours.
    let s = seconds.isFinite ? Int(min(max(0, seconds), 359_999).rounded(.down)) : 0
    let mmss = String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    return s >= 3600 ? "\(s / 3600):\(mmss)" : mmss
}

public struct TranscriptLine: Equatable, Sendable {
    public var stamp: String
    public var at: Double
    public var speaker: String
    public var text: String
}

/// A time into a call as it's written, "12:34" or "1:02:03": the one pattern for it, used wherever one is looked for.
let stampForm = #"\d{1,2}:\d\d(?::\d\d)?"#
private let stampPattern = "(\(stampForm))"
private let transcriptFormats: [NSRegularExpression] = [
    // **[12:34] Name:** text   (Oatcake)
    #"^\*\*\[\#(stampPattern)\]\s+(.+?):\*\*\s*(.*)$"#,
    // [12:34] **Name:** text
    #"^\[\#(stampPattern)\]\s+\*\*(.+?):\*\*\s*(.*)$"#,
    // [12:34] System audio (Name): text   /   [12:34] Microphone: text   (Granola)
    #"^\[\#(stampPattern)\]\s+([^:]{1,80}?):\s+(.*)$"#,
].map { try! NSRegularExpression(pattern: $0) }

func groups(_ match: NSTextCheckingResult, in text: String) -> [String?] {
    (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
}

func firstMatch(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, in: text) }
}

public func parseTranscript(_ markdown: String) -> [TranscriptLine] {
    markdown.components(separatedBy: "\n").compactMap { raw in
        let line = raw.trimmed
        for format in transcriptFormats {
            if let g = firstMatch(format, line), let stamp = g[1], let speaker = g[2] {
                let name = speaker.replacingOccurrences(of: #"^System audio \((.+)\)$"#, with: "$1", options: .regularExpression)
                return TranscriptLine(stamp: padStamp(stamp), at: seconds(stamp), speaker: name, text: g[3] ?? "")
            }
        }
        return nil
    }
}

public struct NoteLine: Equatable, Sendable {
    /// nil for a prep note written before the call.
    public var stamp: String?
    public var text: String
}

private let noteFormat = try! NSRegularExpression(pattern: #"^\s*[-*]\s+(?:\[\#(stampPattern)\]\s+)?(.*)$"#)

public func parseNotes(_ markdown: String) -> [NoteLine] {
    markdown.components(separatedBy: "\n").compactMap { line in
        guard let g = firstMatch(noteFormat, line), let text = g[2]?.trimmed, !text.isEmpty,
              text.range(of: #"^\*\*[^*]+:\*\*"#, options: .regularExpression) == nil else { return nil }
        return NoteLine(stamp: g[1].map(padStamp), text: text)
    }
}

public struct Todo: Equatable, Hashable, Sendable {
    /// Line number in todo.md, for ticking it off.
    public var line: Int
    public var done: Bool
    public var text: String
    public var owner: String
    public var due: String
    public var stamp: String
}

private let todoFormat = try! NSRegularExpression(pattern: #"^\s*[-*]\s+\[( |x|X)\]\s+(.*)$"#)
private let lonelyStamp = try! NSRegularExpression(pattern: #"^\[\#(stampPattern)\]$"#)

/**
 * "- [ ] Task — Owner — due Fri, Oct 30 — [12:34]" (owner, due date and time optional). Only the
 * last piece that isn't the due date or the time is the owner: a task can have a spaced dash of its
 * own ("Compare A — B pricing — John"), and that part stays in the task.
 */
public func parseTodos(_ markdown: String) -> [Todo] {
    markdown.components(separatedBy: "\n").enumerated().compactMap { index, line in
        guard let g = firstMatch(todoFormat, line), let box = g[1], let body = g[2] else { return nil }
        let pieces = body.replacingOccurrences(of: #"\s+—\s+"#, with: "\u{0}", options: .regularExpression).components(separatedBy: "\u{0}")
        var todo = Todo(line: index, done: box != " ", text: pieces[0], owner: "", due: "", stamp: "")
        var words: [String] = []
        for p in pieces.dropFirst() {
            if let stamp = firstMatch(lonelyStamp, p)?[1] ?? nil {
                todo.stamp = padStamp(stamp)
            } else if p.range(of: #"^due\s+"#, options: [.regularExpression, .caseInsensitive]) != nil {
                todo.due = p.replacingOccurrences(of: #"^due\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            } else {
                words.append(p)
            }
        }
        todo.owner = words.popLast() ?? ""
        todo.text = ([pieces[0]] + words).joined(separator: " — ")
        return todo
    }
}

/// todo.md with one item ticked or unticked.
public func toggleTodo(_ markdown: String, line: Int) -> String {
    var lines = markdown.components(separatedBy: "\n")
    guard lines.indices.contains(line), let range = lines[line].range(of: #"\[( |x|X)\]"#, options: .regularExpression) else { return markdown }
    lines[line].replaceSubrange(range, with: lines[line][range] == "[ ]" ? "[x]" : "[ ]")
    return lines.joined(separator: "\n")
}

/**
 * todo.md with the to-do `text` ticked or unticked: the one at `line` when that's still it, otherwise
 * the first with that text, since the file may have changed since the list on screen was read. nil
 * when it's no longer there.
 */
public func toggleTodo(_ markdown: String, line: Int, text: String) -> String? {
    findTodo(markdown, line: line, text: text).map { toggleTodo(markdown, line: $0.line) }
}

private func findTodo(_ markdown: String, line: Int, text: String) -> Todo? {
    let todos = parseTodos(markdown)
    return todos.first(where: { $0.line == line && $0.text == text }) ?? todos.first(where: { $0.text == text })
}

/// todo.md with the to-do `text` (found as toggleTodo finds it) written as `body` instead, its tick
/// kept, or taken out when `body` is nil. nil when it's no longer there.
public func editTodo(_ markdown: String, line: Int, text: String, to body: String?) -> String? {
    guard let found = findTodo(markdown, line: line, text: text) else { return nil }
    var lines = markdown.components(separatedBy: "\n")
    if let body {
        guard let box = lines[found.line].range(of: #"^\s*[-*]\s+\[( |x|X)\]\s+"#, options: .regularExpression) else { return nil }
        lines[found.line] = lines[found.line][..<box.upperBound] + body.trimmed
    } else {
        lines.remove(at: found.line)
    }
    return lines.joined(separator: "\n")
}

/// A to-do as it would be typed to make it again: "Send the deck - Jane - due Fri, Nov 6", for editing it.
public func typedForm(_ todo: Todo) -> String {
    [todo.text, todo.owner, todo.due.isEmpty ? "" : "due \(todo.due)", todo.stamp.isEmpty ? "" : "[\(todo.stamp)]"]
        .filter { !$0.isEmpty }.joined(separator: " - ")
}

/**
 * A typed to-do in todo.md's form. " - " and " -- " count as the separator (an em dash is awkward
 * to type), and `owner` fills in when none is given: "Send the deck - due Fri, Nov 6" with owner
 * "John" becomes "Send the deck — John — due Fri, Nov 6". As in parseTodos, only the last piece that
 * isn't a field is the owner: "Send the deck - draft two - Jane" keeps "Send the deck - draft two".
 */
public func typedTodo(_ text: String, owner: String? = nil) -> String {
    // The pieces, with the separators typed between them (pieces at even places, separators at odd).
    let parts = text.trimmed.replacingOccurrences(of: #"\s+(?:—|--|-)\s+"#, with: "\u{0}$0\u{0}", options: .regularExpression).components(separatedBy: "\u{0}")
    let pieces = stride(from: 0, to: parts.count, by: 2).map { parts[$0] }
    let isField = { (p: String) in
        p.range(of: #"^due\s"#, options: [.regularExpression, .caseInsensitive]) != nil
            || p.range(of: "^\\[\(stampForm)\\]$", options: .regularExpression) != nil
    }
    let named = pieces.indices.dropFirst().last { !isField(pieces[$0]) }
    var task = pieces[0]
    for i in pieces.indices.dropFirst() where !isField(pieces[i]) && i != named { task += parts[2 * i - 1] + pieces[i] }
    let who = named.map { pieces[$0] } ?? owner.flatMap { $0.isEmpty ? nil : $0 }
    return ([task] + (who.map { [$0] } ?? []) + pieces.filter(isField)).joined(separator: " — ")
}

/// todo.md with a new open to-do at the end.
public func addTodo(_ markdown: String, _ text: String) -> String {
    let base = markdown.replacingOccurrences(of: #"\s*$"#, with: "", options: .regularExpression)
    return "\(base.isEmpty ? "" : base + "\n")- [ ] \(text.trimmed)\n"
}

/// A day said the way it is in a call ("tomorrow", "Friday", "next week", "end of the month"), worked
/// out from the day of the meeting. A weekday is the next one, the meeting's own day included.
private func relativeDue(_ due: String, from met: Date) -> Date? {
    let calendar = gregorian
    let day = calendar.startOfDay(for: met)
    let text = due.trimmed.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    func adding(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: day) }
    /// Days from the meeting to the next `weekday` (1 = Sunday), none when it's that day.
    func until(_ weekday: Int) -> Int { (weekday - calendar.component(.weekday, from: day) + 7) % 7 }
    switch text {
    case "today": return day
    case "tomorrow": return adding(1)
    case "next week": return adding(until(2) == 0 ? 7 : until(2))
    case "end of week", "end of the week": return adding(until(6))
    case "end of month", "end of the month":
        return calendar.dateInterval(of: .month, for: day).flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
    default: break
    }
    let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    let name = text.replacingOccurrences(of: #"^(this|next|on|by) "#, with: "", options: .regularExpression)
    guard let index = weekdays.firstIndex(where: { $0 == name || $0.prefix(3) == name }) else { return nil }
    return adding(until(index + 1))
}

/// An item on the combined To-dos page.
public struct TodoItem: Identifiable, Equatable, Sendable {
    public var todo: Todo
    public var meeting: MeetingTodos
    public var dueDate: Date?
    public var id: String { "\(meeting.path):\(todo.line)" }

    public func isOverdue(today: Date = Calendar.current.startOfDay(for: Date())) -> Bool {
        !todo.done && dueDate.map { $0 < today } == true
    }

    /**
     * Its group on the To-dos page grouped by due date. Weeks are calendar weeks: "This week" runs
     * to Sunday, "Next week" the seven days after. They're counted in days on the calendar, not in
     * steps of 24 hours, which in a week the clocks change in end the week an hour out, putting next
     * week's Sunday under Later.
     */
    public func dueGroup(today: Date, calendar: Calendar = gregorian) -> DueGroup {
        guard let due = dueDate else { return .noDate }
        let today = calendar.startOfDay(for: today)
        if due < today { return todo.done ? .dueEarlier : .overdue }
        if calendar.isDate(due, inSameDayAs: today) { return .today }
        let weekday = calendar.component(.weekday, from: today)
        guard let sunday = calendar.date(byAdding: .day, value: (8 - weekday) % 7, to: today),
              let nextSunday = calendar.date(byAdding: .day, value: 7, to: sunday) else { return .later }
        return due <= sunday ? .thisWeek : due <= nextSunday ? .nextWeek : .later
    }
}

/// The To-dos page's groups by due date, in the order they're listed.
public enum DueGroup: Int, CaseIterable, Comparable, Sendable {
    case overdue, dueEarlier, today, thisWeek, nextWeek, later, noDate

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .dueEarlier: "Was due earlier"
        case .today: "Today"
        case .thisWeek: "This week"
        case .nextWeek: "Next week"
        case .later: "Later"
        case .noDate: "No due date"
        }
    }

    public static func < (a: DueGroup, b: DueGroup) -> Bool { a.rawValue < b.rawValue }
}

/**
 * Every to-do as an item, with its due date worked out. Those of a meeting whose todo.md (and title
 * and date) are as they were in `previous` are taken from there: a tick changes one file, and the
 * rest of the library needn't be worked out again. Your own list's are always worked out again: with
 * no meeting to count from, "due tomorrow" counts from today, which changes at midnight.
 */
public func allTodoItems(_ meetings: [MeetingTodos], reusing previous: [TodoItem] = []) -> [TodoItem] {
    let before = Dictionary(grouping: previous, by: \.meeting.path)
    return meetings.flatMap { m in
        if m.startedAt != nil, let items = before[m.path], items.first?.meeting == m { return items }
        return parseTodos(m.todo).map { TodoItem(todo: $0, meeting: m, dueDate: dueDate($0.due, meetingDate: m.startedAt)) }
    }
}

/// The formats a due date is read in, each made once: making a formatter is most of the cost of reading one.
private final class DueFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private let formatters: [DateFormatter] = ["MMM d yyyy", "MMMM d yyyy", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy", "d MMMM yyyy", "yyyy-MM-dd", "M/d/yyyy"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.isLenient = true
        // The day alone is wanted, so it's read as a day in UTC and made a day here below, whatever zone this Mac is in now.
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = $0
        return f
    }

    /// The year, month and day of the first format that reads one of `texts`.
    func day(_ texts: [String]) -> DateComponents? {
        lock.withLock {
            for formatter in formatters {
                if let d = texts.lazy.compactMap({ formatter.date(from: $0) }).first {
                    return formatter.calendar.dateComponents(in: formatter.timeZone, from: d)
                }
            }
            return nil
        }
    }
}
private let dueFormatters = DueFormatters()

/**
 * "Fri, Oct 30" → a date. To-dos give no year, so it's the meeting's year, or the next one when that
 * would put it well before the meeting (a December call agreeing something for January).
 */
public func dueDate(_ due: String, meetingDate: Date? = nil) -> Date? {
    guard !due.trimmed.isEmpty else { return nil }
    let met = meetingDate ?? Date()
    let calendar = gregorian
    if let day = relativeDue(due, from: met) { return day }
    let text = due.replacingOccurrences(of: #"^[A-Za-z]+,\s*"#, with: "", options: .regularExpression).trimmed
    let hasYear = text.range(of: #"\d{4}"#, options: .regularExpression) != nil
    let candidates = hasYear ? [text] : ["\(text) \(calendar.component(.year, from: met))"]
    guard let day = dueFormatters.day(candidates),
          var date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
    if !hasYear, date < met.addingTimeInterval(-60 * 86_400) { date = calendar.date(byAdding: .year, value: 1, to: date)! }
    return calendar.startOfDay(for: date)
}

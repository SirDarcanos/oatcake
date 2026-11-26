import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ParseTests {
    @Test func todos() {
        let md = "- [ ] Send the deck — Jane — due Fri, Nov 6 — [12:34]\n- [x] Book room\nnot a todo\n* [X] Done — John"
        let todos = parseTodos(md)
        #expect(todos.count == 3)
        #expect(todos[0] == Todo(line: 0, done: false, text: "Send the deck", owner: "Jane", due: "Fri, Nov 6", stamp: "12:34"))
        #expect(todos[1].done && todos[1].text == "Book room")
        #expect(todos[2].line == 3 && todos[2].owner == "John")
        #expect(toggleTodo(md, line: 0).hasPrefix("- [x] Send the deck"))
        #expect(toggleTodo(md, line: 1).contains("- [ ] Book room"))
        // By what it says, when the file has changed since the list on screen was read: the line it was on is someone else's now.
        let shifted = "- [ ] New first\n" + md
        #expect(toggleTodo(shifted, line: 0, text: "Send the deck") == "- [ ] New first\n- [x] Send the deck — Jane — due Fri, Nov 6 — [12:34]\n- [x] Book room\nnot a todo\n* [X] Done — John")
        #expect(toggleTodo(shifted, line: 1, text: "Gone since") == nil)
        // A spaced dash in the task itself: only the last piece that isn't a field is the owner.
        let dashed = parseTodos("- [ ] Compare A — B pricing — John — due Fri, Nov 6 — [01:15]\n- [ ] Compare A — B pricing — due Fri\n")
        #expect(dashed[0] == Todo(line: 0, done: false, text: "Compare A — B pricing", owner: "John", due: "Fri, Nov 6", stamp: "01:15"))
        #expect(dashed[1].text == "Compare A" && dashed[1].owner == "B pricing")
    }

    @Test func typedTodos() {
        #expect(typedTodo("Send the deck - due Fri, Nov 6", owner: "John") == "Send the deck — John — due Fri, Nov 6")
        #expect(typedTodo("Send the deck - Jane - due Fri, Nov 6", owner: "John") == "Send the deck — Jane — due Fri, Nov 6")
        // The task keeps a dash of its own, as it was typed.
        let typed = typedTodo("Send the deck - draft two -- Jane - due Fri", owner: "John")
        #expect(typed == "Send the deck - draft two — Jane — due Fri")
        #expect(parseTodos("- [ ] \(typed)").first.map { [$0.text, $0.owner, $0.due] } == ["Send the deck - draft two", "Jane", "Fri"])
        #expect(typedTodo("Send the deck") == "Send the deck" && typedTodo("Send the deck", owner: "") == "Send the deck")
        #expect(typedTodo("  Call Jane — [12:34]  ", owner: "John") == "Call Jane — John — [12:34]")
        #expect(addTodo("- [ ] One\n\n", "Two") == "- [ ] One\n- [ ] Two\n")
        #expect(addTodo("", "Two") == "- [ ] Two\n")
    }

    @Test func transcripts() {
        let lines = parseTranscript("**[00:05] John Smith:** Hello there\n\n[1:02:03] **Jane:** Hi\n[0:20] System audio (Jane Roe): yes\n[0:21] Microphone: me")
        #expect(lines.map(\.speaker) == ["John Smith", "Jane", "Jane Roe", "Microphone"])
        #expect(lines[1].at == 3723)
        #expect(lines[2].stamp == "00:20")
    }

    @Test func notes() {
        let notes = parseNotes("- [03:09] Budget agreed\n- Prep question\n- **Date:** skip me\n")
        #expect(notes == [NoteLine(stamp: "03:09", text: "Budget agreed"), NoteLine(stamp: nil, text: "Prep question")])
    }

    @Test func previews() {
        #expect(previewOf("# Title\n- **Date:** x\n\n## Summary\n- Updates \\& **Welcomes** [12:34] [link](http://x)") == "Updates & Welcomes link")
        #expect(forReading("## Summary\nBody") == "Body")
    }

    @Test func dueDates() {
        let met = parseISO("2026-12-14T10:00:00Z")!
        let jan = dueDate("Fri, Jan 8", meetingDate: met)!
        #expect(gregorian.component(.year, from: jan) == 2027)
        #expect(gregorian.component(.month, from: dueDate("Oct 30", meetingDate: parseISO("2026-10-01T10:00:00Z"))!) == 10)
        #expect(dueDate("whenever") == nil)
        // A day as it's said in a call, counted from the day of the meeting: Monday the 14th of December 2026, at noon here.
        let monday = gregorian.date(from: DateComponents(year: 2026, month: 12, day: 14, hour: 12))!
        let day = { (said: String) in dueDate(said, meetingDate: monday).map { gregorian.dateComponents([.month, .day], from: $0) }.map { [$0.month!, $0.day!] } }
        #expect(day("today") == [12, 14] && day("Tomorrow") == [12, 15])
        #expect(day("Friday") == [12, 18] && day("next Friday") == [12, 18] && day("by Wed") == [12, 16] && day("Monday") == [12, 14])
        #expect(day("next week") == [12, 21] && day("end of the week") == [12, 18] && day("end of month") == [12, 31])
        #expect(day("soon") == nil && day("Fri, Jan 8") == [1, 8])
    }

    @Test func clocks() {
        #expect(clock(189) == "03:09")
        #expect(clock(3729) == "1:02:09")
        #expect(seconds("1:02:03") == 3723)
        // A time that isn't one (a damaged import) is still something to show.
        #expect(clock(-5) == "00:00" && clock(.infinity) == "00:00" && clock(.nan) == "00:00" && clock(1e300) == "99:59:59")
    }

    /// Only an older file's own header is taken off: a title with the lines older versions wrote
    /// under it (counted in a real Meetings folder: Date, Participants, Granola note, Granola folders).
    @Test func olderHeaders() {
        #expect(stripHeader("# Old\n- **Date:** 2026-10-29\n- **Participants:** John, Jane\n\n---\n\n## Summary\nBody") == "## Summary\nBody")
        #expect(stripHeader("\n# Imported\n- **Granola note:** https://notes.granola.ai/d/x\n- **Granola folders:** Team\nText") == "Text")
        // A summary written to your own instructions keeps its title and its bullets, bold or not.
        let own = "# Launch plan\n- **Decision:** ship on the 4th\n- **Owner:** John\n"
        #expect(stripHeader(own) == own && forReading(own) == own)
        #expect(stripHeader("# Launch plan\n\nWe agreed the dates.") == "# Launch plan\n\nWe agreed the dates.")
        #expect(previewOf("# Launch plan\n\nWe agreed the dates.") == "We agreed the dates.")
        #expect(previewOf(own) == "Decision: ship on the 4th")
        #expect(stripHeader("No heading\n- **Date:** x") == "No heading\n- **Date:** x")
    }

    /// The To-dos page: every meeting's to-dos, each with its due date worked out, and overdue once that day has passed.
    @Test func todosAcrossMeetings() {
        let day = { (d: Int) in gregorian.date(from: DateComponents(year: 2026, month: 11, day: d))! }
        let meeting = MeetingTodos(path: "Team/2026-11-02 1000 Sync", title: "Sync", startedAt: day(2).addingTimeInterval(36_000),
                                   todo: "- [ ] Send the deck — Jane — due Nov 4 — [12:34]\n- [x] Book the room — due Nov 3\nnot a to-do\n- [ ] Think about it\n- [ ] Call Jane — due Friday\n")
        let own = MeetingTodos(path: "", title: "To-dos", startedAt: nil, todo: "- [ ] Renew the domain — John\n")
        let items = allTodoItems([own, meeting])
        #expect(items.map(\.todo.text) == ["Renew the domain", "Send the deck", "Book the room", "Think about it", "Call Jane"])
        #expect(items.map(\.id) == [":0", "Team/2026-11-02 1000 Sync:0", "Team/2026-11-02 1000 Sync:1", "Team/2026-11-02 1000 Sync:3", "Team/2026-11-02 1000 Sync:4"])
        // The 2nd was a Monday: "Friday" is the 6th.
        #expect(items.map(\.dueDate) == [nil, day(4), day(3), nil, day(6)])
        // Due the 4th: not overdue on the day, overdue the day after. Done, or with no date: never.
        #expect(items.map { $0.isOverdue(today: day(4)) } == [false, false, false, false, false])
        #expect(items.map { $0.isOverdue(today: day(5)) } == [false, true, false, false, false])
        #expect(items.map { $0.isOverdue(today: day(7)) } == [false, true, false, false, true])

        // Read again after a tick in one meeting: the other's items are kept as they were worked out
        // (marked here, to tell), and only the changed one's are worked out afresh.
        var marked = items
        for i in marked.indices { marked[i].dueDate = day(30) }
        let ticked = with(meeting) { $0.todo = toggleTodo($0.todo, line: 0) }
        let again = allTodoItems([own, ticked], reusing: marked)
        #expect(again.map(\.dueDate) == [day(30), day(4), day(3), nil, day(6)])
        #expect(again[1].todo.done && !items[1].todo.done)
    }
}

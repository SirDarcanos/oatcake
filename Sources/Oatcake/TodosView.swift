import OatcakeCore
import SwiftUI

/// Every meeting's to-dos in one place. Ticking one updates that meeting's todo.md.
struct TodosView: View {
    @Environment(AppModel.self) private var model
    private let homePreview: Bool

    init(homePreview: Bool = false) {
        self.homePreview = homePreview
    }

    enum Status: Hashable { case open, done, all }
    enum Grouping: Hashable { case due, folder, owner }
    /// Whose to-dos are listed.
    enum Owner: Hashable { case everyone, mine, named(String) }

    @ViewState private var status = Status.open
    @ViewState private var grouping = Grouping.due
    @ViewState private var owner = Owner.everyone
    @ViewState private var adding = false
    @ViewState private var draft = ""
    /// A list's text straight after a tick or an add here, until the app has read it back from disk,
    /// so two quick ticks in one meeting don't undo each other.
    @ViewState private var local: [String: String] = [:]
    @FocusState private var addFocused: Bool

    private let day: TimeInterval = 86_400

    var body: some View {
        let myName = model.config.myName
        let today = Calendar.current.startOfDay(for: model.calendar.now)
        // The items were worked out when the to-dos were read. Only a list just ticked or added to
        // here is read afresh, from its text as it is now.
        let items = local.isEmpty ? model.library.todoItems
            : model.library.todoItems.filter { local[$0.meeting.path] == nil } + allTodoItems(model.library.todoMeetings.compactMap { m in
                local[m.path].map { text in with(m) { $0.todo = text } }
            })
        SwiftUI.Group {
            if homePreview {
                preview(items, today: today, myName: myName)
            } else {
                fullPage(items, today: today, myName: myName)
            }
        }
        .onChange(of: model.library.todoMeetings) {
            local = local.filter { path, text in model.library.todoMeetings.first { $0.path == path }?.todo != text }
        }
    }

    @ViewBuilder private func preview(_ items: [TodoItem], today: Date, myName: String) -> some View {
        let open = items.filter { !$0.todo.done }
        let list = open.sorted(by: dueFirst).prefix(5)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("To-dos").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if open.count > list.count {
                    Text("Showing \(list.count) of \(open.count) open")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("View all to-dos") { model.selection = .todos }.buttonStyle(.link)
            }
            if list.isEmpty {
                Text("No open to-dos.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { item in
                    row(item, today: today, myName: myName, showOwner: true)
                    Divider()
                }
                addField.padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false) }
        }
    }

    private func dueFirst(_ a: TodoItem, _ b: TodoItem) -> Bool {
        let da = a.dueDate ?? .distantFuture, db = b.dueDate ?? .distantFuture
        return da != db ? da < db : (a.meeting.startedAt ?? .distantPast) > (b.meeting.startedAt ?? .distantPast)
    }

    private func fullPage(_ items: [TodoItem], today: Date, myName: String) -> some View {
        let open = items.filter { !$0.todo.done }
        let overdue = items.filter { $0.isOverdue(today: today) }
        // One ticked in Open leaves the list at once. It's under Done, where a mis-tick can be undone.
        var list = items.filter { status == .open ? !$0.todo.done : status == .done ? $0.todo.done : true }
        switch owner {
        case .everyone: break
        case .mine: list = list.filter { isMe($0.todo.owner, myName) }
        case .named(let name): list = list.filter { $0.todo.owner == name }
        }
        list.sort(by: dueFirst)
        let groups = grouped(list, today: today, myName: myName)
        let owners = Array(Set(items.map(\.todo.owner).filter { !$0.isEmpty && !isMe($0, myName) })).sorted()
        // Your own list (the Meetings folder's todo.md) isn't a meeting.
        let fromMeetings = Set(open.filter { !$0.meeting.path.isEmpty }.map(\.meeting.path)).count
        let fromYourList = open.contains { $0.meeting.path.isEmpty }
        let sources = [fromMeetings > 0 ? "\(fromMeetings) meeting\(fromMeetings == 1 ? "" : "s")" : nil, fromYourList ? "your list" : nil]
            .compactMap { $0 }.joined(separator: " and ")

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "To-dos")
                Text("\(open.count) open\(overdue.isEmpty ? "" : " · \(overdue.count) overdue")\(sources.isEmpty ? "" : " · from \(sources)"). Ticking one ticks it in its meeting too.")
                    .foregroundStyle(.secondary).padding(.top, 6)
                addField.padding(.top, 22)
                // How adding works, only while adding.
                if addFocused {
                    Text("Saved in your Meetings folder’s own todo.md, as yours unless you name someone: Send the deck - Jane - due Fri, Nov 6. To add one to a meeting, use the to-dos at the top of its summary.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                ForEach(groups, id: \.key) { group in
                    HStack(spacing: 6) {
                        if grouping == .owner, let o = group.items.first?.todo.owner, !o.isEmpty { Avatar(name: o, size: 18) }
                        Text(group.label).foregroundStyle(group.key == "0" && grouping == .due ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        Text("\(group.items.count)").foregroundStyle(.tertiary)
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                    ForEach(group.items) { item in row(item, today: today, myName: myName, showOwner: grouping != .owner) }
                }
                if groups.isEmpty {
                    Text(status == .done ? "Nothing ticked off yet." : owner == .everyone ? "No open to-dos." : "No open to-dos for this person.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            // What's shown, then how it's arranged.
            ToolbarItem(placement: .automatic) {
                Picker("Show", selection: $status) {
                    Text("Open · \(open.count)").tag(Status.open)
                    Text("Done").tag(Status.done)
                    Text("All").tag(Status.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            ToolbarItemGroup(placement: .automatic) {
                Picker("Group by", selection: $grouping) {
                    Text("Due date").tag(Grouping.due)
                    Text("Folder").tag(Grouping.folder)
                    Text("Owner").tag(Grouping.owner)
                }
                .fixedSize()
                Picker("Owner", selection: $owner) {
                    Text("Everyone").tag(Owner.everyone)
                    Text("Mine").tag(Owner.mine)
                    ForEach(owners, id: \.self) { Text($0).tag(Owner.named($0)) }
                }
                .fixedSize()
            }
        }
    }

    private struct Group {
        var key: String
        var label: String
        var items: [TodoItem]
    }

    private func grouped(_ list: [TodoItem], today: Date, myName: String) -> [Group] {
        // Calendar weeks: "This week" runs to Sunday, "Next week" the seven days after.
        let weekday = Calendar.current.component(.weekday, from: today)
        let endOfWeek = today.addingTimeInterval(Double((8 - weekday) % 7) * day)
        func bucket(_ t: TodoItem) -> (String, String) {
            guard let d = t.dueDate else { return ("6", "No due date") }
            if d < today { return t.todo.done ? ("1", "Was due earlier") : ("0", "Overdue") }
            if d == today { return ("2", "Today") }
            if d <= endOfWeek { return ("3", "This week") }
            if d <= endOfWeek.addingTimeInterval(7 * day) { return ("4", "Next week") }
            return ("5", "Later")
        }
        func key(_ t: TodoItem) -> (String, String) {
            switch grouping {
            case .folder:
                let f = t.meeting.path.isEmpty ? "" : parentOf(t.meeting.path)
                return (folderPath(f), folderPath(f))
            case .owner:
                if isMe(t.todo.owner, myName) { return ("0", "You") }
                return t.todo.owner.isEmpty ? ("2", "No owner") : ("1" + t.todo.owner, t.todo.owner)
            case .due:
                return bucket(t)
            }
        }
        var groups: [String: Group] = [:]
        for t in list {
            let (k, label) = key(t)
            groups[k, default: Group(key: k, label: label, items: [])].items.append(t)
        }
        return groups.values.sorted { $0.key < $1.key }
    }

    private func row(_ item: TodoItem, today: Date, myName: String, showOwner: Bool) -> some View {
        let late = item.isOverdue(today: today)
        let folder = item.meeting.path.isEmpty ? "" : parentOf(item.meeting.path)
        let date = item.meeting.startedAt.map { compactDate($0) } ?? ""
        return HStack(alignment: homePreview ? .center : .top, spacing: 10) {
            TodoCheckbox(checked: item.todo.done, what: item.todo.text) { tick(item) }
                .padding(.top, homePreview ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.todo.text).strikethrough(item.todo.done).textSelection(.enabled)
                HStack(spacing: 8) {
                    if item.meeting.path.isEmpty {
                        Text("Your list").foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.openMeeting(item.meeting.path, jump: Jump(tab: .summary))
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(folder.isEmpty ? Color.secondary : Color.accentColor).frame(width: 6, height: 6)
                                // The meeting itself, so two to-dos with the same words from different meetings can be told apart.
                                Text("\(item.meeting.title)\(date.isEmpty ? "" : " · \(date)")")
                            }
                        }
                        .buttonStyle(.link)
                        .help("Open this meeting")
                    }
                    if !item.todo.stamp.isEmpty {
                        Chip(text: item.todo.stamp) { model.openMeeting(item.meeting.path, jump: Jump(tab: .transcript, stamp: item.todo.stamp)) }
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            // Grouped by owner, the group heading already names them.
            if showOwner {
                HStack(spacing: 5) {
                    if !item.todo.owner.isEmpty {
                        Avatar(name: item.todo.owner, size: 18)
                        Text(ownerLabel(item.todo.owner, myName)).lineLimit(1)
                    }
                }
                .font(.callout)
                .frame(width: 150, alignment: homePreview ? .trailing : .leading)
            }
            // Overdue says so in more than red.
            HStack(spacing: 4) {
                if late { Image(systemName: "exclamationmark.circle").accessibilityHidden(true) }
                Text(dueLabel(item, today: today)).lineLimit(1)
            }
                .accessibilityLabel(late ? "Overdue, due \(dueLabel(item, today: today))" : dueLabel(item, today: today))
                .font(.callout).monospacedDigit()
                .foregroundStyle(late ? AnyShapeStyle(.red) : item.dueDate == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                // Room for the overdue mark beside "Mon 23 Nov".
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private func dueLabel(_ item: TodoItem, today: Date) -> String {
        guard let due = item.dueDate else { return "No date" }
        let d = Int((due.timeIntervalSince(today) / day).rounded())
        return d == 0 ? "Today" : d == 1 ? "Tomorrow" : shortDay(due, now: today)
    }

    private var addField: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.quaternary)
                .accessibilityHidden(true)
            TextField("Add a to-do, then Return", text: $draft)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .help("Yours unless you name someone: Send the deck - Jane - due Fri, Nov 6")
                .onSubmit(add)
        }
    }

    /// To-dos added here go in the Meetings folder's own todo.md, owned by you unless you name someone.
    private func add() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        do {
            try model.library.addTodo("", typedTodo(text, owner: model.config.myName))
            local[""] = onDisk("")
            draft = ""
            model.toast("Added to Meetings › todo.md")
        } catch {
            model.toast(error.localizedDescription, isError: true)
        }
    }

    /// A list as its file is now. The file is changed as it stands, never written over with what
    /// this page last read, so this is what's shown until the app has read it back too.
    private func onDisk(_ path: String) -> String? { try? model.library.readMeeting(path).todo }

    private func tick(_ item: TodoItem) {
        do {
            guard try model.library.toggleTodo(item.meeting.path, line: item.todo.line, text: item.todo.text) else {
                // It isn't in the file as it's shown here: nothing was ticked, and the list is read again.
                withAnimation { local[item.meeting.path] = nil }
                return model.toast(todoChangedMessage)
            }
            withAnimation { local[item.meeting.path] = onDisk(item.meeting.path) }
            model.toast("Saved to \(item.meeting.path.isEmpty ? "Meetings" : folderPath(item.meeting.path)) › todo.md")
        } catch {
            model.toast(error.localizedDescription, isError: true)
        }
    }
}

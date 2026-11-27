import EventKit
import OatcakeCore
import SwiftUI

extension SettingsView {
    @ViewBuilder var calendar: some View {
        Section {
            CalendarSettingsRows(calendar: model.calendar, editor: $calendarEditor)
        } header: {
            Text("Calendars")
        } footer: {
            Text("In Google Calendar, open Settings, pick a calendar under “Settings for my calendars”, then copy its “Secret address in iCal format” from Integrate calendar. Any other calendar that gives you an iCal (.ics) address, starting https:// or webcal://, works the same way. Repeat for each calendar you want in Upcoming. Or choose Add from this Mac… for calendars already in this Mac’s Calendar app.")
                .settingsHint()
        }
        Section("Reminders") {
            Toggle(isOn: bind(\.callReminders)) {
                Text("Remind me before calls")
                Text("Before each call, a notification with a button that opens the call and starts recording, ready for notes.")
            }
            if model.config.callReminders {
                ReminderTimesRows(minutes: bind(\.reminderMinutes))
                notificationsHint
            }
            Toggle(isOn: bind(\.menuBarNextCall)) {
                Text("Show my next call in the menu bar")
                Text("The time until it starts, with what’s coming up in its menu.")
            }
        }
        // Typed as one comma-separated line, like Jargon; kept as a list.
        Section {
            // Named on the left with the field on the right, as Your name is: alone, the line read as a sentence.
            TextField("Leave out", text: $ignoredEvents, prompt: Text("Focus time, Out of office"), axis: .vertical)
                .lineLimit(1...4)
                .onChange(of: ignoredEvents) {
                    let titles = commaList(ignoredEvents)
                    if titles != model.config.ignoredEvents { model.saveConfig(with(model.config) { $0.ignoredEvents = titles }) }
                }
        } header: {
            Text("Events that aren’t calls")
        } footer: {
            Text("Separated by commas. Events whose titles start with one of these, or have “Oatcake ignore” anywhere in them, are left out of Upcoming, the menu bar and reminders. Capitals don’t matter, and “Task” doesn’t leave out “Taskforce sync”.")
                .settingsHint()
        }
        // Ignored one at a time from Upcoming's right-click menu. Only shown once there are some.
        let ignored = withoutEnded(model.config.ignoredCalendarEvents, now: Date())
        if !ignored.isEmpty {
            Section {
                ForEach(ignored) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.series ? "This and following events" : parseISO(item.start).map { dayAndTime($0) } ?? "Once")
                                .settingsHint()
                        }
                        Spacer()
                        Button("Stop ignoring") { model.stopIgnoring(item) }
                    }
                }
            } header: {
                Text("Ignored events")
            } footer: {
                Text("Right-click an event in Upcoming to ignore it. Only Oatcake leaves it out: it stays in your calendar. An event its organiser moves shows again, and so does the rest of a series changed with “this and following events”.")
                    .settingsHint()
            }
        }
    }
}

struct CalendarSettingsEdit: Identifiable {
    let id = UUID()
    let existing: CalendarController.Label?
    /// Choosing from this Mac's calendars rather than adding or editing one.
    var fromThisMac = false
}

struct CalendarSettingsRows: View {
    let calendar: CalendarController
    @Binding var editor: CalendarSettingsEdit?
    /// Add from this Mac… was chosen: if access is refused, that's said even with none added yet.
    @ViewState private var askedForMac = false

    var body: some View {
        Group {
            if let problem = calendar.settingsProblem {
                Text(problem).settingsHint()
            }
            ForEach(calendar.calendars) { source in
                LabeledContent {
                    Button("Edit…") { editor = CalendarSettingsEdit(existing: source) }
                        .accessibilityLabel("Edit \(source.name)")
                        .help("Edit \(source.name)")
                } label: {
                    HStack(spacing: 6) {
                        CalendarBadges(calendars: [source])
                        Text(source.name)
                    }
                    Text(calendar.status(for: source.id)).settingsHint()
                }
            }
            HStack {
                Button("Add calendar…") { editor = CalendarSettingsEdit(existing: nil) }
                    .help("Add a calendar by its private iCal address")
                Button("Add from this Mac…") {
                    askedForMac = true
                    Task { if await calendar.allowMacCalendars() { editor = CalendarSettingsEdit(existing: nil, fromThisMac: true) } }
                }
                .help("Add calendars that are in this Mac’s Calendar app")
            }
            .disabled(calendar.settingsProblem != nil)
            if askedForMac || calendar.hasMacCalendars { macAccessHint }
        }
    }

    /// Why this Mac's calendars can't be read, and where to change that.
    @ViewBuilder private var macAccessHint: some View {
        switch calendar.macAccess {
        case .allowed: EmptyView()
        case .notAsked:
            // Only for calendars already added (their permission was withdrawn with tccutil, say):
            // otherwise macOS is asking right now.
            if calendar.hasMacCalendars {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Oatcake needs your permission to read this Mac’s calendars.").settingsHint(.amber)
                    Button("Allow access…") { Task { await calendar.allowMacCalendars() } }.controlSize(.small)
                }
            }
        case .refused:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Oatcake isn’t allowed to read this Mac’s calendars. Give it full access in System Settings › Privacy & Security › Calendars.").settingsHint(.amber)
                Button("Open Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        case .restricted:
            Text("This Mac doesn’t let apps read its calendars: that’s set by Screen Time, or by whoever manages this Mac.").settingsHint(.amber)
        }
    }
}

/// Settings › Calendars › Add from this Mac…: the calendars in this Mac's Calendar app that haven't
/// been added yet, to tick.
struct MacCalendarPicker: View {
    @Environment(\.dismiss) private var dismiss
    let calendar: CalendarController
    @ViewState private var choices: [MacCalendars.Choice] = []
    @ViewState private var chosen: Set<String> = []
    @ViewState private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add calendars from this Mac").font(.title2.weight(.semibold))
            if choices.isEmpty {
                Text("There are no other calendars on this Mac to add. Calendars appear here once their account is set up in the Calendar app.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Form {
                    ForEach(choices) { choice in
                        Toggle(isOn: Binding(get: { chosen.contains(choice.id) },
                                             set: { if $0 { chosen.insert(choice.id) } else { chosen.remove(choice.id) } })) {
                            Text(choice.title)
                            if !choice.account.isEmpty { Text(choice.account) }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: min(CGFloat(choices.count) * 44 + 24, 320))
                Text("Their events are read on this Mac and stay on it. Each one gets a badge colour, which Edit… changes.")
                    .settingsHint()
            }
            if let problem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
        .onAppear { choices = calendar.macCalendarChoices() }
        // Calendars the Mac finishes loading after access is given, or that change while this is open.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in choices = calendar.macCalendarChoices() }
    }

    private func add() {
        do {
            try calendar.addFromThisMac(choices.filter { chosen.contains($0.id) })
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// Settings › Calendars › Reminders: how long before each call its reminders come, a row for each.
struct ReminderTimesRows: View {
    @Binding var minutes: [Int]
    private static let choices = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    var body: some View {
        // Earliest first, as they'll come.
        ForEach(Array(minutes.enumerated()), id: \.offset) { index, chosen in
            LabeledContent("Reminder") {
                HStack(spacing: 8) {
                    Picker("Reminder", selection: Binding(get: { chosen }, set: { change(index, to: $0) })) {
                        ForEach(Array(Set(Self.choices + [chosen])).sorted(), id: \.self) { Text(Self.label($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // The last one stays: turning reminders off is the switch above.
                    if minutes.count > 1 {
                        Button { minutes.remove(at: index) } label: {
                            // Drawn at its own size, but 24 points to click, as the app's other small buttons are.
                            Image(systemName: "minus.circle").frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                            .buttonStyle(.borderless)
                            .help("Remove this reminder")
                            .accessibilityLabel("Remove the reminder \(Self.label(chosen))")
                    }
                }
            }
        }
        if let next = Self.choices.first(where: { !minutes.contains($0) }) {
            Button("Add reminder") { minutes = (minutes + [next]).sorted(by: >) }
                .help("Another reminder before each call, \(Self.label(next))")
        }
    }

    private func change(_ index: Int, to value: Int) {
        var changed = minutes
        changed[index] = value
        minutes = Array(Set(changed)).sorted(by: >)
    }

    static func label(_ minutes: Int) -> String {
        minutes == 60 ? "1 hour before" : minutes == 1 ? "1 minute before" : "\(minutes) minutes before"
    }
}

struct CalendarEditor: View {
    @Environment(\.dismiss) private var dismiss
    let calendar: CalendarController
    let existing: CalendarController.Label?
    @ViewState private var name: String
    @ViewState private var colour: SwatchColour
    @ViewState private var address = ""
    @ViewState private var problem: String?
    @ViewState private var removing = false

    init(calendar: CalendarController, existing: CalendarController.Label?) {
        self.calendar = calendar
        self.existing = existing
        _name = ViewState(initialValue: existing?.name ?? "")
        _colour = ViewState(initialValue: existing?.colour ?? calendar.nextColour)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add calendar" : "Edit calendar").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Work or Personal"))
                LabeledContent("Badge colour") {
                    CalendarColourButton(title: name.trimmed.isEmpty ? "Badge colour" : "\(name.trimmed)’s colour",
                                         colour: colour) { colour = $0 }
                }
                if existing?.onThisMac == true {
                    LabeledContent("Events", value: "From this Mac’s Calendar app")
                } else {
                    SecureField("Private iCal address", text: $address,
                                prompt: Text(existing == nil ? "Paste the address" : "Leave blank to keep the saved address"))
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if existing != nil {
                    Button("Remove calendar…", role: .destructive) { removing = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 450)
        .alert("Remove this calendar?", isPresented: $removing) {
            Button("Remove", role: .destructive) {
                guard let existing else { return }
                do { try calendar.remove(existing.id); dismiss() }
                catch { problem = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its events will no longer appear in Oatcake unless they’re on another connected calendar. Your saved meetings are unchanged.")
        }
    }

    private func save() {
        do {
            try calendar.save(id: existing?.id, name: name, colour: colour, address: address)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

private struct CalendarColourButton: View {
    let title: String
    let colour: SwatchColour
    let choose: (SwatchColour) -> Void
    @ViewState private var showing = false

    var body: some View {
        Button { showing = true } label: {
            // A body-text baseline keeps the circle centred alongside the Form’s label.
            Text("●").hidden().frame(width: 22, height: 22)
                .overlay { Circle().fill(colour.swatch) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(colour.title)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ColourSwatchPopover(title: title, selected: colour, choose: { choice in
                choose(choice)
                showing = false
            })
        }
    }
}

import OatcakeCore
import SwiftUI

struct CalendarSettingsEdit: Identifiable {
    let id = UUID()
    let existing: CalendarController.Label?
}

struct CalendarSettingsRows: View {
    let calendar: CalendarController
    @Binding var editor: CalendarSettingsEdit?

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
            Button("Add calendar…") { editor = CalendarSettingsEdit(existing: nil) }
                .help("Add a calendar")
                .disabled(calendar.settingsProblem != nil)
        }
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
                SecureField("Private iCal address", text: $address,
                            prompt: Text(existing == nil ? "Paste the address" : "Leave blank to keep the saved address"))
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

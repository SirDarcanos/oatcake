import OatcakeCore
import SwiftUI

/// The middle column: the selected folder's meetings, newest first (every meeting for the top level).
struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    /// Passed in rather than read here: inside the split view, this column doesn't always see the
    /// model change by itself.
    let folder: TreeNode?
    @ViewState private var renaming: TreeNode?
    /// The meetings selected with ⌘- or ⇧-click. One selected meeting is the open one, so this only
    /// matters when there are several.
    @ViewState private var picked: Set<String> = []
    @ViewState private var draft = ""

    var body: some View {
        // The top level lists every meeting, each labelled with the folder it's in.
        let everything = folder?.path.isEmpty ?? true
        let rows = listedIn(folder)
        // What's listed, and how many, are named in the toolbar above the list, as Mail names a mailbox.
        let title = everything ? "All meetings" : baseName(folder!.path)
        let subtitle = "\(everything || parentOf(folder!.path).isEmpty ? "" : folderPath(parentOf(folder!.path)) + " · ")\(rows.count) meeting\(rows.count == 1 ? "" : "s")"
        Group {
            if rows.isEmpty {
                VStack(spacing: 10) {
                    // A folder lists only its own meetings: one whose meetings are all in the folders inside it says so.
                    let inside = folder?.allMeetings.count ?? 0
                    Text(everything ? "No meetings yet."
                         : inside == 1 ? "This folder’s one meeting is in a folder inside it."
                         : inside > 1 ? "This folder’s \(inside) meetings are in the folders inside it."
                         : "No meetings in this folder yet.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { model.newRecording() } label: { Label(everything ? "New recording" : "Record here", systemImage: "circle.fill") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Picking a meeting leaves this list as it is, rather than swapping it for the meeting's folder.
                // Picking several (⌘- or ⇧-click) leaves the open meeting open, for acting on them all at once.
                let listed = Set(rows.map(\.path))
                let chosen = rows.filter { selected(in: listed).contains($0.path) }
                List(selection: Binding(get: { selected(in: listed) }, set: { paths in
                    picked = paths
                    if paths.count == 1, let p = paths.first { model.selectMeeting(p) }
                })) {
                    ForEach(rows) { row($0, everything: everything, folder: folder?.path ?? "").tag($0.path) }
                }
                .listStyle(.plain)
                // Right-clicking a selected meeting acts on every selected one; any other, on just that one.
                .contextMenu(forSelectionType: String.self) { paths in
                    let nodes = rows.filter { paths.contains($0.path) }
                    if nodes.count == 1, let m = nodes.first {
                        Button("Rename…") { draft = meetingTitle(m); renaming = m }
                        Button("Show in Finder") { model.library.reveal(m.path) }
                        Divider()
                        Button("Move to Trash") { model.library.trash([m]) }
                    } else if nodes.count > 1 {
                        Button("Show in Finder") { model.library.reveal(nodes.map(\.path)) }
                        Divider()
                        Button("Move \(nodes.count) Meetings to Trash") { model.trash(nodes) }
                    }
                }
                // File › Move to Trash (⌘⌫, as in Finder) acts on the selection while the list has the
                // keyboard; the next meeting opens, as in Mail.
                .focusedValue(\.trashMeetings, chosen.isEmpty ? nil : { model.trash(chosen) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // Search, over the list: it opens over the window and finds meetings anywhere. A button
        // rather than a field, which didn't fit beside the folder's name with the sidebar hidden.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { if model.searching { model.searching = false } else { model.searchMeetings() } } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                    .help("Search every meeting’s title, folder, summary, to-dos, notes and transcript (⌥⌘F)")
            }
        }
        // A meeting opened from elsewhere (the sidebar, a search, a reminder) ends a selection of several.
        .onChange(of: selectedPath) { picked = [] }
        .alert("Rename meeting", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $draft)
            Button("Rename") { if let node = renaming { model.library.retitle(node.path, to: draft) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes the meeting’s title and its folder’s name.")
        }
    }

    private var selectedPath: String? {
        if case .meeting(let path, _) = model.selection { return path }
        return nil
    }

    /// What the list shows as selected: the meetings picked, while there are several still listed;
    /// otherwise the open meeting.
    private func selected(in listed: Set<String>) -> Set<String> {
        let several = picked.intersection(listed)
        return several.count > 1 ? several : Set([selectedPath].compactMap { $0 })
    }

    private func row(_ m: TreeNode, everything: Bool, folder: String) -> some View {
        let date = meetingDate(m)
        let title = meetingTitle(m)
        let calendars = model.calendar.labels(for: m.calendarIDs)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(date.map { "\(shortWeekday($0)), \(compactDate($0))" } ?? m.name).fontWeight(.semibold).lineLimit(1)
                if let date {
                    Text("·").foregroundStyle(.tertiary)
                    Text(hhmm(date)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 4)
                if m.granola {
                    Text("Granola").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.fill))
                }
            }
            if everything || !sameAsFolder(title, folder) || !calendars.isEmpty {
                let parent = parentOf(m.path)
                HStack(spacing: 5) {
                    CalendarBadges(calendars: calendars, describe: true)
                    if everything, !parent.isEmpty {
                        (Text(folderPath(parent)).fontWeight(.medium) + Text(sameAsFolder(title, parent) ? "" : " · \(title)").foregroundStyle(.secondary))
                            .lineLimit(1)
                    } else {
                        Text(title).fontWeight(.medium).lineLimit(1)
                    }
                }
            }
            if !m.preview.isEmpty {
                Text(m.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .draggable(dragPrefix + m.path)
    }
}

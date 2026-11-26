import OatcakeCore
import SwiftUI

/// The middle column: the selected folder's meetings, newest first (every meeting for the top
/// level), or the meetings a search finds anywhere.
struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    /// Passed in rather than read here: inside the split view, this column doesn't always see the
    /// model change by itself.
    let folder: TreeNode?
    /// The whole Meetings folder, which search looks through.
    let root: TreeNode?
    /// What's typed in the toolbar's search field.
    let query: String
    @ViewState private var renaming: TreeNode?
    /// The meetings selected with ⌘- or ⇧-click. One selected meeting is the open one, so this only
    /// matters when there are several.
    @ViewState private var picked: Set<String> = []
    @ViewState private var draft = ""
    /// What the last search of every meeting's text found, and the words it was for.
    @ViewState private var found: (query: String, hits: [SearchHit])?

    var body: some View {
        // The top level lists every meeting, each labelled with the folder it's in; so does a search.
        let search = query.trimmed
        let everything = !search.isEmpty || (folder?.path.isEmpty ?? true)
        let hits = search.isEmpty || found?.query != search ? [:] : Dictionary(uniqueKeysWithValues: (found?.hits ?? []).map { ($0.path, $0) })
        let rows = search.isEmpty ? listedIn(folder) : results(search)
        // What's listed, and how many, are named in the toolbar above the list, as Mail names a mailbox.
        let title = !search.isEmpty ? "Search" : everything ? "All meetings" : baseName(folder!.path)
        let subtitle = "\(everything || parentOf(folder!.path).isEmpty ? "" : folderPath(parentOf(folder!.path)) + " · ")\(rows.count) meeting\(rows.count == 1 ? "" : "s")"
        Group {
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text(!search.isEmpty ? "No meetings match “\(search)”." : everything ? "No meetings yet." : "No meetings in this folder yet.")
                        .foregroundStyle(.secondary)
                    if search.isEmpty {
                        Button { model.newRecording() } label: { Label(everything ? "New recording" : "Record here", systemImage: "circle.fill") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Picking a meeting leaves this list as it is, rather than swapping it for the meeting's folder.
                // Picking several (⌘- or ⇧-click) leaves the open meeting open, for acting on them all at once.
                let listed = Set(rows.map(\.path))
                let chosen = rows.filter { selected(in: listed).contains($0.path) }
                List(selection: Binding(get: { selected(in: listed) }, set: { paths in
                    picked = paths
                    if paths.count == 1, let p = paths.first { open(p, hit: hits[p]) }
                })) {
                    ForEach(rows) { row($0, everything: everything, folder: folder?.path ?? "", hit: hits[$0.path]).tag($0.path) }
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
                        Button("Move \(nodes.count) Meetings to Trash") { model.library.trash(nodes) }
                    }
                }
                // File › Move to Trash (⌘⌫, as in Finder) acts on the selection while the list has the keyboard.
                .focusedValue(\.trashMeetings, chosen.isEmpty ? nil : { model.library.trash(chosen) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // A meeting opened from elsewhere (the sidebar, a search, a reminder) ends a selection of several.
        .onChange(of: selectedPath) { picked = [] }
        // Searched again when the words change, and when a meeting does.
        .task(id: "\(model.library.diskVersion) \(search)") { await searchText(search) }
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

    /// What a meeting is listed as, besides its text.
    private func label(_ m: TreeNode) -> String { "\(meetingTitle(m)) \(folderPath(parentOf(m.path)))" }

    /// The meetings a search lists, newest first: those with all the words typed in their title, folder,
    /// summary, to-dos, notes or transcript. Until every meeting's text has been looked through (a
    /// moment after you stop typing), it's the ones with the words in their title or folder.
    private func results(_ search: String) -> [TreeNode] {
        if let found, found.query == search { return found.hits.compactMap { root?.find($0.path) } }
        let words = search.split(separator: " ").map(String.init)
        return listedIn(root).filter { m in words.allSatisfy { label(m).localizedStandardContains($0) } }
    }

    /// Looks through every meeting's text, off the main thread. Each file is read once and kept until it changes.
    private func searchText(_ search: String) async {
        guard !search.isEmpty else { return found = nil }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let all = listedIn(root).map { (path: $0.path, label: label($0)) }
        let meetings = model.library.meetings, todos = model.config.todosEnabled
        let hits = await Task.detached { meetings.search(search, in: all, todos: todos) }.value
        if !Task.isCancelled { found = (search, hits) }
    }

    /// Opens a meeting picked in the list. One that a search found in its text opens where the words are.
    private func open(_ path: String, hit: SearchHit?) {
        guard let file = hit?.file else { return model.selectMeeting(path) }
        let tab: MeetingTab = file == .transcript ? .transcript : file == .notes ? .notes : .summary
        model.selectMeeting(path, jump: Jump(tab: tab, stamp: hit?.stamp))
    }

    private func row(_ m: TreeNode, everything: Bool, folder: String, hit: SearchHit?) -> some View {
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
            if let hit, let file = hit.file, !hit.line.isEmpty {
                // Found in the meeting's text: the line that has the words, and where it is.
                let place = [MeetingFile.summary: "Summary", .todo: "To-dos", .notes: "My notes", .transcript: "Transcript"][file] ?? ""
                (Text("\(place) · ").fontWeight(.medium) + Text(hit.line))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if !m.preview.isEmpty {
                Text(m.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .draggable(dragPrefix + m.path)
    }
}

import OatcakeCore
import SwiftUI

/// Search, over the window (⌥⌘F, or the button over the meeting list): the meetings with every word
/// typed in their title, folder, summary, to-dos, notes or transcript, newest first, as you type.
/// ↑ and ↓ choose one, Return or a click opens it where the words are, and Escape or a click
/// outside closes it.
struct SearchOverlay: View {
    @Environment(AppModel.self) private var model
    /// The whole Meetings folder. Passed in, as the meeting list's folder is.
    let root: TreeNode?
    @ViewState private var query = ""
    /// What the last search of every meeting's text found, and the words it was for.
    @ViewState private var found: (query: String, hits: [SearchHit])?
    /// The result Return opens: the first, then whichever ↑, ↓ or the pointer picks.
    @ViewState private var chosen = 0
    @ViewState private var listHeight: CGFloat = 0

    var body: some View {
        let search = query.trimmed
        let rows = results(search)
        let hits = found?.query == search ? Dictionary((found?.hits ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        ZStack(alignment: .top) {
            Color.black.opacity(0.1)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                field(rows, hits: hits)
                if !search.isEmpty {
                    Divider()
                    if rows.isEmpty {
                        Text("No meetings match “\(search)”.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    } else {
                        list(rows, hits: hits)
                    }
                }
            }
            .frame(width: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 60)
        }
        .onExitCommand { close() }
        .onChange(of: search) { chosen = 0 }
        // Searched again when the words change, and when a meeting does.
        .task(id: "\(model.library.diskVersion) \(search)") { await searchText(search) }
    }

    private func field(_ rows: [TreeNode], hits: [String: SearchHit]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
            KeyedTextField(text: $query, placeholder: "Search meetings",
                           font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize),
                           onMove: { chosen = min(max(chosen + $0, 0), max(rows.count - 1, 0)) },
                           onReturn: { if rows.indices.contains(chosen) { open(rows[chosen], hit: hits[rows[chosen].path]) } },
                           onEscape: { close() })
                .accessibilityLabel("Search meetings")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear the search").accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// As tall as the results, up to 420 points, then scrolling.
    private func list(_ rows: [TreeNode], hits: [String: SearchHit]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let words = searchWords(query)
                    ForEach(Array(rows.enumerated()), id: \.element.path) { i, m in
                        row(m, hit: hits[m.path], words: words, chosen: i == chosen)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { open(m, hit: hits[m.path]) }
                            .onHover { if $0 { chosen = i } }
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 420))
            .onChange(of: chosen) { proxy.scrollTo(chosen) }
        }
    }

    private func row(_ m: TreeNode, hit: SearchHit?, words: [String], chosen: Bool) -> some View {
        let parent = parentOf(m.path)
        let secondary = chosen ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(markingFound(meetingTitle(m), words)).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 8)
                if let date = meetingDate(m) { Text(compactDate(date)).foregroundStyle(secondary).monospacedDigit() }
            }
            if !parent.isEmpty { Text(markingFound(folderPath(parent), words)).font(.callout).foregroundStyle(secondary).lineLimit(1) }
            if let hit, let file = hit.file, !hit.line.isEmpty {
                // Found in the meeting's text: the line that has the words, and where it is.
                let place = [MeetingFile.summary: "Summary", .todo: "To-dos", .notes: "My notes", .transcript: "Transcript"][file] ?? ""
                (Text("\(place) · ").fontWeight(.medium) + Text(markingFound(hit.line, words)))
                    .font(.callout).foregroundStyle(secondary).lineLimit(2)
            }
        }
        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chosen ? Color.accentColor : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// What a meeting is found by, besides its text.
    private func label(_ m: TreeNode) -> String { "\(meetingTitle(m)) \(folderPath(parentOf(m.path)))" }

    /// Until every meeting's text has been looked through (a moment after you stop typing), the
    /// meetings with the words in their title or folder.
    private func results(_ search: String) -> [TreeNode] {
        guard !search.isEmpty else { return [] }
        if let found, found.query == search { return found.hits.compactMap { root?.find($0.path) } }
        let words = searchWords(search)
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

    /// Opens a meeting, in the list of its folder. One found by its text opens where the words are,
    /// with them in Find and marked, as Mail marks a search's words in a message it opens.
    private func open(_ m: TreeNode, hit: SearchHit?) {
        close()
        guard let file = hit?.file else { return model.openMeeting(m.path) }
        let tab: MeetingTab = file == .transcript ? .transcript : file == .notes ? .notes : .summary
        // Find gets the words found in the text, not those that were only in the title or folder:
        // it looks for lines with all of them, and wouldn't find one.
        let words = searchWords(query)
        let inText = words.filter { !label(m).localizedStandardContains($0) }
        model.openMeeting(m.path, jump: Jump(tab: tab, stamp: hit?.stamp, words: inText.isEmpty ? words : inText))
    }

    private func close() { model.searching = false }
}

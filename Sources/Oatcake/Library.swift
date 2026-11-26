// The Meetings folder as the window shows it: its folders and meetings, their to-dos, and everything
// that renames, moves, trashes, reads or writes them. Imports from Granola and Quill land here too.

import AppKit
import OatcakeCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class Library {
    /// What this part asks of the app around it.
    var app = AppServices()
    /// A folder or meeting now lives somewhere else: whatever knew it by its old path follows it.
    var whenMoved: @MainActor (_ from: String, _ to: String) -> Void = { _, _ in }
    /// Meetings (or folders) have gone to the Trash, by their paths: what was kept for them elsewhere can go too.
    var whenTrashed: @MainActor (_ paths: [String]) -> Void = { _ in }
    private var config: Config { app.config() }
    private func toast(_ text: String, isError: Bool = false) { app.toast(text, isError) }
    private func refresh() { app.refresh() }
    private func moved(from: String, to: String) { whenMoved(from, to) }

    private(set) var meetings: Meetings
    var tree: TreeNode?
    /// Bumps on every change on disk, so open meetings re-read their files.
    var diskVersion = 0
    /// macOS has said something in the Meetings folder changed since it was last read.
    @ObservationIgnored private var changedOnDisk = false
    /// Every meeting's to-dos as last read, and what's worked out from them when they're read (not
    /// each time something that shows them is redrawn): each to-do as an item, and the sidebar's counts.
    private(set) var todoMeetings: [MeetingTodos] = []
    private(set) var todoItems: [TodoItem] = []
    private(set) var todoCounts: (open: Int, overdue: Int) = (0, 0)
    /// The day the counts were made on: what's overdue changes at midnight.
    private var countedOn = Date.distantPast
    /// What the last import from Granola or Quill did, in words, and whether it failed. Kept here
    /// rather than in Settings' row, so it's still there if Settings was closed while it ran.
    var importOutcomes: [String: (text: String, failed: Bool)] = [:]
    private var watcher: FolderWatcher?

    init(root: URL) {
        meetings = Meetings(root: root)
    }

    /// The Meetings folder is somewhere else from now on.
    func open(_ root: URL) {
        meetings = Meetings(root: root)
        watchMeetings()
    }

    // Keep the sidebar in step with Finder.
    func watchMeetings() {
        try? FileManager.default.createDirectory(at: meetings.root, withIntermediateDirectories: true)
        watcher = FolderWatcher(meetings.root) { [weak self] in
            self?.changedOnDisk = true
            self?.refresh()
        }
    }

    /// Whether macOS has said something changed since the last read, for the read starting now.
    func takeChangedOnDisk() -> Bool {
        defer { changedOnDisk = false }
        return changedOnDisk
    }

    /// What a read of the Meetings folder found: the tree, when it isn't the one already shown, and
    /// whether files changed since the read before. A read that found nothing new redraws nothing,
    /// and open meetings aren't read again for it.
    func landed(_ tree: TreeNode?, changedOnDisk: Bool) {
        if let tree { self.tree = tree }
        if tree != nil || changedOnDisk { diskVersion += 1 }
    }

    func rename(_ path: String, to name: String) {
        guard !name.trimmed.isEmpty, name.trimmed != baseName(path) else { return }
        attempt { moved(from: path, to: try meetings.rename(path, to: name)) }
    }

    /// A meeting's new title, in meeting.json and in its folder's name.
    func retitle(_ path: String, to title: String) {
        guard !title.trimmed.isEmpty else { return }
        attempt { moved(from: path, to: try meetings.retitle(path, to: title)) }
    }

    /// Moves what was dropped on a folder: one meeting or folder, or every meeting picked in the list.
    /// Ones already there are left alone. One that can't be moved stops the rest, and the toast says
    /// how many went before it and why, as Move to Trash does.
    func move(_ paths: [String], into target: String) {
        let paths = paths.filter { $0 != target && !target.hasPrefix($0 + "/") && parentOf($0) != target }
        guard !paths.isEmpty else { return }
        var count = 0
        do {
            for path in paths {
                moved(from: path, to: try meetings.move(path, into: target))
                count += 1
            }
        } catch {
            toast(paths.count == 1 ? error.localizedDescription
                                   : "Moved \(count) of \(paths.count) meetings to \(folderPath(target)) — \(error.localizedDescription)", isError: true)
            return
        }
        toast(paths.count == 1 ? "Moved to \(folderPath(target))" : "Moved \(paths.count) meetings to \(folderPath(target))")
    }

    @discardableResult
    func createFolder(in parent: String, named name: String) -> String? {
        var made: String?
        attempt { made = try meetings.createFolder(in: parent, named: name) }
        refresh()
        return made
    }

    /// Moves meetings or folders to the Trash, and returns the paths that went. One that can't be moved
    /// stops the rest, and the toast says how many went before it and why. Edit › Undo (⌘Z) puts them back.
    @discardableResult
    func trash(_ nodes: [TreeNode]) -> [String] {
        var gone: [String] = []
        var inTrash: [(node: TreeNode, url: URL)] = []
        // Put back into the Meetings folder they came from, even if another has been chosen since.
        let from = meetings
        defer {
            whenTrashed(nodes.prefix(moved).map(\.path))
            refresh()
            if !inTrash.isEmpty, let undo = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.undoManager {
                let items = inTrash
                undo.registerUndo(withTarget: self) { $0.putBack(items, into: from) }
                undo.setActionName("Move to Trash")
            }
        }
        do {
            for node in nodes {
                if let url = try from.trash(node.path) { inTrash.append((node, url)) }
                gone.append(node.path)
            }
        } catch {
            toast(nodes.count == 1 ? error.localizedDescription
                                   : "Moved \(gone.count) of \(nodes.count) meetings to the Trash — \(error.localizedDescription)", isError: true)
            return gone
        }
        if nodes.count == 1, let node = nodes.first {
            toast("Moved “\(name(node))” to the Trash")
        } else if !nodes.isEmpty {
            toast("Moved \(nodes.count) meetings to the Trash")
        }
        return gone
    }

    /// Undo for Move to Trash: back from the Trash to where they were, the last to go first.
    private func putBack(_ items: [(node: TreeNode, url: URL)], into meetings: Meetings) {
        defer { refresh() }
        var back = 0
        do {
            for item in items.reversed() {
                try meetings.putBack(item.url, to: item.node.path)
                back += 1
            }
        } catch {
            toast("Couldn’t put “\(name(items[items.count - 1 - back].node))” back: \(error.localizedDescription). It’s still in the Trash.", isError: true)
            return
        }
        toast(items.count == 1 ? "Put “\(name(items[0].node))” back from the Trash" : "Put \(items.count) meetings back from the Trash")
    }

    private func name(_ node: TreeNode) -> String { node.kind == .meeting ? meetingTitle(node) : node.name }

    /// A folder's Move to Trash. One with meetings in it asks first: it takes them all with it.
    func trashFolder(_ node: TreeNode) {
        let count = node.allMeetings.count
        guard count > 0 else {
            trash([node])
            return
        }
        app.confirm(Confirmation(title: "Move “\(node.name)” to the Trash?",
                                    text: "It holds \(count == 1 ? "1 meeting, which goes" : "\(count) meetings, which go") with it. You can put \(count == 1 ? "it" : "them") back from the Trash in Finder.",
                                    ok: "Move to Trash", cancel: "Cancel") { [self] in trash([node]) })
    }

    func reveal(_ path: String) { reveal([path]) }

    func reveal(_ paths: [String]) {
        let urls = paths.compactMap { try? resolveInside(meetings.root, $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func readMeeting(_ path: String) throws -> MeetingFiles { try meetings.read(path) }

    /// Ticks or unticks a to-do in todo.md as it is now, not as a view last read it: a tick never
    /// writes back over to-dos that have arrived since (the summary's, say). `text` is the to-do's
    /// task, which finds it if its line has moved. "" is the Meetings folder's own list.
    /// False when the to-do isn't in the file any more (it was reworded or removed there): nothing was written.
    @discardableResult
    func toggleTodo(_ path: String, line: Int, text: String) throws -> Bool {
        let ticked = try meetings.toggleTodo(path, line: line, text: text)
        refresh()
        return ticked
    }

    /// Adds a to-do to the end of todo.md as it is now.
    func addTodo(_ path: String, _ text: String) throws {
        try meetings.addTodo(path, text)
        refresh()
    }

    /// Rewrites a to-do in todo.md as it is now, or takes it out (`body` nil). False when it isn't
    /// in the file any more: nothing was written.
    func editTodo(_ path: String, line: Int, text: String, to body: String?) throws -> Bool {
        let changed = try meetings.editTodo(path, line: line, text: text, to: body)
        refresh()
        return changed
    }

    /// A meeting's todo.md alone, as it is now; nil when it can't be read.
    func readTodo(_ path: String) -> String? { try? meetings.readTodo(path) }

    /**
     * Ticks or unticks a to-do, wherever it's shown, in todo.md as it is now (toggleTodo), and ⌘Z
     * ticks it back. `shown` is given the file as it is afterwards, for the screen to show at once,
     * or nil when nothing was ticked: the to-do isn't in the file as shown (which the toast says)
     * or the file couldn't be written. The screen then reads its to-dos again.
     */
    func tick(_ path: String, _ todo: Todo, undo: UndoManager?, shown: @escaping @MainActor (String?) -> Void) {
        do {
            guard try toggleTodo(path, line: todo.line, text: todo.text) else {
                toast(todoChangedMessage)
                return shown(nil)
            }
            shown(readTodo(path))
            undo?.registerUndo(withTarget: self) { library in
                MainActor.assumeIsolated { library.tick(path, todo, undo: undo, shown: shown) }
            }
        } catch {
            toast(error.localizedDescription, isError: true)
            shown(nil)
        }
    }

    /// Rename speakers…: other names for a saved meeting's speakers, in that meeting only.
    func renameSpeakers(_ path: String, _ renames: [String: String]) {
        attempt { try meetings.renameSpeakers(path, renames, me: config.myName) }
        refresh()
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { toast(error.localizedDescription, isError: true) }
    }

    /// What's being imported ("Granola", "Quill"), if anything. Kept here rather than in the Settings
    /// row, which starts afresh if its window is closed and opened again: one import at a time.
    var importing: String?

    /// Settings › Import from Granola: pick the export, import it, and show the new meetings.
    func importGranolaExport(progress: @escaping ImportProgress) async {
        await runImport("Granola", types: [.zip, .commaSeparatedText], progress: progress) { url, root in
            try importGranola(url, into: root, progress: progress)
        }
    }

    /// Settings › Import from Quill: pick Quill's backup, import it, and show the new meetings.
    func importQuillBackup(progress: @escaping ImportProgress) async {
        let me = config.myName
        await runImport("Quill", types: [.zip], progress: progress) { url, root in
            try importQuill(url, into: root, me: me, progress: progress)
        }
    }

    /// Picks the file, imports it off the main thread, and leaves what happened in `importOutcomes`.
    private func runImport(_ source: String, types: [UTType], progress: @escaping ImportProgress,
                           _ work: @escaping @Sendable (URL, URL) throws -> ImportResult) async {
        let panel = NSOpenPanel()
        panel.title = "Import from \(source)"
        panel.prompt = "Import"
        panel.allowedContentTypes = types
        guard importing == nil, panel.runModal() == .OK, let url = panel.url else { return }
        importing = source
        defer { importing = nil }
        let root = meetings.root
        progress(0, 0)
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        do {
            let r = try await Task.detached { try work(url, root) }.value
            let text = [r.imported > 0 ? "Imported \(plural(r.imported, "meeting")) into the \(r.folder) folder." : "Nothing new to import.",
                        r.skipped > 0 ? "\(plural(r.skipped, "meeting")) already here." : nil,
                        r.unreadable > 0 ? "\(plural(r.unreadable, "meeting")) couldn't be read." : nil].compactMap { $0 }.joined(separator: " ")
            importOutcomes[source] = (text, false)
            refresh()
        } catch {
            importOutcomes[source] = (error.localizedDescription, true)
        }
    }

    /// The to-dos as just read from the Meetings folder, and their items when they were worked out
    /// with them (off the main thread); otherwise only the meetings whose to-dos changed are worked out.
    func setTodos(_ todos: [MeetingTodos], items: [TodoItem]? = nil) {
        // Unchanged, on the same day: what was worked out still stands.
        if todos == todoMeetings, Calendar.current.isDateInToday(countedOn) { return }
        todoMeetings = todos
        todoItems = items ?? allTodoItems(todos, reusing: todoItems)
        countTodos()
    }

    /// Counted again when the day has changed since, so yesterday's "due today" becomes overdue.
    func countTodosIfNewDay() {
        guard !Calendar.current.isDateInToday(countedOn) else { return }
        // Your own list's "due tomorrow" counts from today (allTodoItems), so it's worked out again.
        todoItems = allTodoItems(todoMeetings, reusing: todoItems)
        countTodos()
    }

    private func countTodos() {
        todoCounts = (todoItems.filter { !$0.todo.done }.count, todoItems.filter { $0.isOverdue() }.count)
        countedOn = Date()
    }
}

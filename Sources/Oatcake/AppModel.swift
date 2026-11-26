// The app as a whole: its settings, where you are in the window, what it says to you (toasts and
// questions), and the parts that do the work, wired together here. The parts are the Meetings
// folder (Library), the call being recorded (RecordingController), recordings after the call
// (Jobs), the language model's downloads (ModelDownloads) and the calendar (CalendarController).

import AppKit
import OatcakeCore
import SwiftUI

/// What the detail pane shows.
enum Selection: Equatable {
    case home
    /// A meeting, optionally opened on a tab at a transcript time (the nonce makes a repeat jump count).
    case meeting(String, jump: Jump? = nil)
    case todos
    case folder(String)
    case new(CalendarEvent?, key: UUID = UUID())
    case live
    case job(String)
}

struct Jump: Equatable {
    var tab: MeetingTab
    var stamp: String?
    /// Words a search found the meeting by: the meeting opens with them in Find, marked.
    var words: [String] = []
    var nonce = UUID()
}

/// `draft` is shown only in meetings with a draft for sharing (or one on its way).
enum MeetingTab: String, CaseIterable { case summary, transcript, notes, draft }

/// "Stop recording?" and the like: a question with a destructive answer.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var ok: String
    var cancel: String
    var action: () async throws -> Void
}

/// What the parts of the app ask of the app around them: the settings, a word to the person using
/// it, and where they are in the window. Each part is given one; none of them sees AppModel itself.
@MainActor
struct AppServices {
    var config: @MainActor () -> Config = { Config.defaults() }
    var toast: @MainActor (_ text: String, _ isError: Bool) -> Void = { _, _ in }
    /// Asks a question with a destructive answer.
    var confirm: @MainActor (Confirmation) -> Void = { _ in }
    /// Takes a question back if it's still the one being asked: what it asked about has been settled another way.
    var withdraw: @MainActor (Confirmation.ID) -> Void = { _ in }
    /// Something on disk has changed: read the Meetings folder and the recordings again.
    var refresh: @MainActor () -> Void = {}
    /// The same, returning once what was read is in place.
    var refreshed: @MainActor () async -> Void = {}
    var showWindow: @MainActor () -> Void = {}
    var selection: @MainActor () -> Selection? = { nil }
    var select: @MainActor (Selection?) -> Void = { _ in }
    /// Back to the meeting list, on the folder it was showing.
    var showFolder: @MainActor () -> Void = {}
}

@MainActor @Observable
final class AppModel {
    var config: Config
    let library: Library
    let recording: RecordingController
    let jobs: Jobs
    let downloads: ModelDownloads
    let calendar: CalendarController
    /// Bumped by ⌘F: the open meeting shows Find.
    var findRequest = 0
    /// Search (⌥⌘F, or its button over the meeting list) is open over the window.
    var searching = false
    /// File › New Folder: the sidebar asks for the new top-level folder's name. It waits here until the
    /// sidebar takes it, which is after the window has opened if it was closed.
    var wantsNewFolder = false
    var selection: Selection?
    /// The folder the middle column lists.
    var folder = ""
    var confirmation: Confirmation?
    /// Markdown typed in meetings and not written yet, kept here rather than by the meeting's view so
    /// that quitting and updating can write it too (saveEdits).
    var edits = MeetingEdits()
    var toastText: String?
    /// The toast showing says something went wrong: it stays longer, and goes when it's clicked.
    var toastIsError = false
    let updater = Updater()
    let ask = AskChat()
    /// Turning off "Let other apps read my meetings" couldn't be saved, so apps can still read them.
    private(set) var mcpOffNotSaved = false
    /// Why the settings couldn't be read at launch, until it has been shown.
    private var configProblem: String?
    private var timers: [Timer] = []
    private var toastTask: Task<Void, Never>?
    /// A read of the Meetings folder is under way, and another has been asked for since it began.
    private var refreshing = false
    private var refreshWanted = false
    /// Waiting for a read that starts after they asked (refreshed()).
    private var waitingForRead: [CheckedContinuation<Void, Never>] = []
    var openMainWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?

    init() {
        let (config, problem) = Config.loadWithProblem()
        self.config = config
        configProblem = problem
        library = Library(root: config.meetingsRoot)
        downloads = ModelDownloads()
        calendar = CalendarController()
        jobs = Jobs(downloads: downloads)
        recording = RecordingController(calendar: calendar, downloads: downloads)
        wire()
    }

    /// Gives each part what it asks of the app, and of the other parts.
    private func wire() {
        let app = AppServices(config: { [unowned self] in self.config },
                              toast: { [unowned self] text, isError in self.toast(text, isError: isError) },
                              confirm: { [unowned self] in self.confirmation = $0 },
                              withdraw: { [unowned self] id in if self.confirmation?.id == id { self.confirmation = nil } },
                              refresh: { [unowned self] in self.refresh() },
                              refreshed: { [unowned self] in await self.refreshed() },
                              showWindow: { [unowned self] in self.showWindow() },
                              selection: { [unowned self] in self.selection },
                              select: { [unowned self] in self.selection = $0 },
                              showFolder: { [unowned self] in self.openFolder(self.folder) })
        library.app = app
        recording.app = app
        jobs.app = app
        downloads.app = app
        calendar.app = app
        library.whenMoved = { [unowned self] from, to in self.moved(from: from, to: to) }
        // A meeting saved without checking who's who keeps voice clips in Oatcake's own folder: they go with it.
        // Edits still waiting for them have nowhere to go.
        library.whenTrashed = { [unowned self] paths in
            self.jobs.tidySavedRecordings()
            self.edits.discard(paths)
        }
        calendar.changed = { [unowned self] in self.recording.updateMenuBar() }
        recording.folderForEvent = { [unowned self] title, recurring in try self.library.meetings.folderForEvent(title: title, recurring: recurring) }
        recording.ended = { [unowned self] rec in self.jobs.progress[rec.id] = JobProgress() }
    }

    /// Why the settings couldn't be read at launch, once: Oatcake is on its defaults, and should say so.
    func takeConfigProblem() -> String? {
        defer { configProblem = nil }
        return configProblem
    }

    func start() {
        // Left by the Electron version: its secrets move into private.json, its speech models and
        // Chromium caches go. Once: after that there's nothing of its to find. (A secret that couldn't
        // be moved stays in its file, and this is tried again at the next launch.)
        if !UserDefaults.standard.bool(forKey: "electronCleanUpDone") {
            Secrets.migrateFromElectron()
            SpeechModels.removeOldModels()
            try? FileManager.default.removeItem(at: Paths.data.appendingPathComponent("Chromium"))
            if !FileManager.default.fileExists(atPath: Paths.data.appendingPathComponent("secrets.json").path) {
                UserDefaults.standard.set(true, forKey: "electronCleanUpDone")
            }
        }
        // Kept in the Keychain by 0.4.0 to 0.5.2: the calendar's address moves to private.json, once.
        if movesFromKeychain, !UserDefaults.standard.bool(forKey: keychainMoveDone), Secrets.moveFromKeychain() {
            UserDefaults.standard.set(true, forKey: keychainMoveDone)
        }
        Secrets.forgetRetired()
        // The recording permissions given to earlier versions are withdrawn, to be asked for again by
        // this one (Recordings.withdrawEarlierPermissions). Once, and only by a copy whose signature
        // says which versions it stands for: a development build's doesn't. Tried again at the next
        // launch if it couldn't be done.
        if !UserDefaults.standard.bool(forKey: "earlierPermissionsWithdrawn"), let id = Bundle.main.bundleIdentifier {
            let bundle = Bundle.main.bundleURL
            Task.detached {
                guard let requirement = try? Update.designatedRequirement(bundle), requirement.contains("CFBundleShortVersionString") else { return }
                if Recordings.withdrawEarlierPermissions(of: id) { UserDefaults.standard.set(true, forKey: "earlierPermissionsWithdrawn") }
            }
        }
        // A language model left running by a copy of Oatcake that didn't get to stop it.
        ModelServer.stopLeftover()
        jobs.tidySavedRecordings()

        recording.resumeRecordings()
        library.watchMeetings()
        // Load the library before the window shows, so the meeting list and Home's to-dos are ready at launch.
        library.tree = library.meetings.tree()
        if let tree = library.tree { library.setTodos(library.meetings.allTodos(in: tree)) }
        jobs.pending = Recordings.list().filter { $0.state == .recorded || $0.state == .processed }
        jobs.unchecked = Recordings.unchecked()
        // A recording picked up again above has opened its live view: Home only when nothing has.
        if selection == nil { selection = .home }
        refresh()
        calendar.start()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.calendar.now = Date()
                self.library.countTodosIfNewDay()
                self.calendar.checkReminders()
                self.recording.updateMenuBar()
                // The language model gives its memory back after ten minutes with nothing to write.
                await ModelServer.shared.stopIfIdle(for: 600)
            }
        })
        recording.startChecks()
        recording.menuBar.stop = { [weak self] in self?.stopFromMenuBar() }
        recording.menuBar.open = { [weak self] in self?.showWindow() }
        recording.menuBar.record = { [weak self] in self?.newRecording() }
        recording.menuBar.settings = { [weak self] in self?.showSettings() }
        recording.menuBar.openEvent = { [weak self] event in self?.openEvent(event) }
        recording.updateMenuBar()
        updater.start(autoCheck: { [weak self] in self?.config.updateCheck ?? false },
                      busy: { [weak self] in self?.whyUpdateWaits() })
    }

    // MARK: - Meetings folder

    /// Reads the Meetings folder and the recordings again, for every part that shows them.
    func refresh() {
        // One read at a time. However many more are asked for while it runs, there's one more after
        // it: that one sees everything that changed, and no earlier read can land on top of a later one.
        if refreshing {
            refreshWanted = true
            return
        }
        refreshing = true
        let meetings = library.meetings
        // This read sees everything those waiting asked for; anyone asking from now on waits for the next.
        let waiting = waitingForRead
        waitingForRead = []
        Task {
            let (tree, pending, unchecked, todos) = await Task.detached {
                // The folder is walked once: the to-dos are read from the tree just built.
                let tree = meetings.tree()
                return (tree, Recordings.list().filter { $0.state == .recorded || $0.state == .processed }, Recordings.unchecked(),
                        meetings.allTodos(in: tree))
            }.value
            refreshing = false
            defer {
                for continuation in waiting { continuation.resume() }
                if refreshWanted {
                    refreshWanted = false
                    refresh()
                }
            }
            // Another Meetings folder was chosen while this one was being read: its read is on its way.
            guard library.meetings === meetings else { return }
            // Without animation: the sidebar's outline animates rows in when a section (Needs review)
            // appears, and leaves a stray copy of an expanded folder's selected row behind.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                self.library.tree = tree
                self.jobs.pending = pending
                self.jobs.unchecked = unchecked
                self.library.setTodos(todos)
                self.library.diskVersion += 1
            }
            jobs.startWaiting()
            jobs.updateBadge()
        }
    }

    /// Reads the Meetings folder and the recordings again, and returns once what's read is in place.
    func refreshed() async {
        await withCheckedContinuation { continuation in
            waitingForRead.append(continuation)
            refresh()
        }
    }

    /// Writes the Markdown edits waiting to be saved, in one meeting or in all. An edit whose file was
    /// changed meanwhile is put beside it, and that's said; one that can't be written stays waiting.
    @discardableResult
    func saveEdits(in meeting: String? = nil) -> [MeetingEdits.Outcome] {
        let outcomes = edits.save(to: library.meetings, in: meeting)
        for case .setAside(let key, let name) in outcomes {
            toast("\(key.file.rawValue) changed while you were typing in it, so Oatcake didn’t save over it. What you typed is in “\(name)”, beside it in the meeting’s folder.",
                  isError: true)
        }
        return outcomes
    }

    func openMeeting(_ path: String, jump: Jump? = nil) {
        guard library.tree?.find(path)?.kind == .meeting else { return }
        folder = parentOf(path)
        selection = .meeting(path, jump: jump)
    }

    /// Opens a meeting picked in the middle column, which stays as it is (all meetings, a folder, or
    /// search results) rather than switching to the meeting's own folder.
    func selectMeeting(_ path: String, jump: Jump? = nil) {
        guard library.tree?.find(path)?.kind == .meeting else { return }
        selection = .meeting(path, jump: jump)
    }

    /// ⌥⌘F: search, over whatever is open.
    func searchMeetings() {
        showWindow()
        searching = true
    }

    func openFolder(_ path: String) {
        folder = path
        if let first = listedIn(library.tree?.find(path)).first {
            selection = .meeting(first.path)
        } else {
            selection = .folder(path)
        }
    }

    /// A folder or meeting now lives at `to` (renamed or moved).
    func moved(from: String, to: String) {
        let remap = { (p: String) in p == from ? to : p.hasPrefix(from + "/") ? to + p.dropFirst(from.count) : p }
        folder = remap(folder)
        jobs.moved(remap)
        edits.moved(remap)
        switch selection {
        case .meeting(let p, let jump): selection = .meeting(remap(p), jump: jump)
        case .folder(let p): selection = .folder(remap(p))
        default: break
        }
        refresh()
    }

    /// A passing note at the bottom of the window. One that says something went wrong stays for
    /// eight seconds or until it's clicked, and is read out by VoiceOver, which never sees the note itself.
    func toast(_ text: String, isError: Bool = false) {
        withAnimation {
            toastText = text
            toastIsError = isError
        }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 8 : 2.4))
            if !Task.isCancelled { withAnimation { toastText = nil } }
        }
        if isError, let window = NSApp.mainWindow ?? NSApp.keyWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation { toastText = nil }
    }

    // MARK: - Settings

    func saveConfig(_ new: Config) {
        // The Meetings folder only changes through the folder picker.
        var saved = new
        saved.outputDir = config.outputDir
        // A control that sets what it already shows (a picker redrawn, a field losing focus) changes nothing.
        guard saved != config else { return }
        // Turning MCP on approves the Meetings folder as it is now: one put in its place later isn't read.
        let mcpChanged = saved.mcpEnabled != config.mcpEnabled
        saved.mcpApprovedRoot = mcpChanged
            ? (saved.mcpEnabled ? try? MCPServer.RootIdentity.approve(saved.meetingsRoot) : nil)
            : config.mcpApprovedRoot
        config = saved
        persistSettings(disablingMCP: mcpChanged && !saved.mcpEnabled)
        recording.settingsChanged(saved)
        // To-dos turned off while their page is open: back to the meetings.
        if !saved.todosEnabled, selection == .todos { openFolder(folder) }
    }

    /// Upcoming's Ignore: this occurrence, or with `series` every occurrence of its recurring event, is
    /// left out of Upcoming, the menu bar, reminders and call notices. Only in Oatcake: the calendar
    /// isn't changed. Settings › Calendars lists them, to bring one back. Ones that have ended are
    /// forgotten as this is saved.
    func ignore(_ event: CalendarEvent, series: Bool) {
        guard let item = series ? IgnoredEvent.series(of: event) : .occurrence(event) else { return }
        saveConfig(with(config) { $0.ignoredCalendarEvents = withoutEnded($0.ignoredCalendarEvents, now: Date()).filter { !$0.covers(item) } + [item] })
        toast(series ? "“\(event.title)” is ignored from now on. Settings › Calendars can bring it back."
                     : "“\(event.title)”, \(shortWeekday(event.startDate)) \(hhmm(event.startDate)), is ignored. Settings › Calendars can bring it back.")
    }

    func stopIgnoring(_ item: IgnoredEvent) {
        saveConfig(with(config) { $0.ignoredCalendarEvents = withoutEnded($0.ignoredCalendarEvents, now: Date()).filter { !$0.covers(item) } })
    }

    /// Saves the microphone choice and switches any running recording to it.
    func setMic(_ mic: MicChoice?) {
        var c = config
        c.mic = mic
        saveConfig(c)
    }

    func retrySavingMCPOff() {
        guard mcpOffNotSaved, !config.mcpEnabled else { return }
        persistSettings(disablingMCP: true)
    }

    private func persistSettings(disablingMCP: Bool = false, movingLibrary: Bool = false) {
        do {
            try config.save()
            mcpOffNotSaved = false
        } catch {
            if disablingMCP { mcpOffNotSaved = true }
            let detail = movingLibrary ? ", so Oatcake will be back on the old folder next time" : ""
            toast("Couldn’t save your settings\(detail): \(error.localizedDescription)", isError: true)
        }
    }

    func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Into the folder they were typed in, before it's another.
        saveEdits()
        config.outputDir = url.path
        config.mcpApprovedRoot = config.mcpEnabled ? try? MCPServer.RootIdentity.approve(config.meetingsRoot) : nil
        persistSettings(movingLibrary: true)
        library.open(url)
        refresh()
    }

    /// Whether this copy moves the calendar's address out of the Keychain. Not a development copy
    /// pointed at another data folder: it would copy your real address into that folder, and its
    /// flag (in the UserDefaults it shares with your own copy) would stop your own copy's move.
    private var movesFromKeychain: Bool { ProcessInfo.processInfo.environment["OATCAKE_DATA_DIR"] == nil }
    private let keychainMoveDone = "secretsMovedFromKeychain"

    // MARK: - Around the window

    /// A clicked reminder: New recording for its event, unless a call is already being recorded.
    func openEvent(_ event: CalendarEvent) {
        showWindow()
        selection = recording.live != nil ? .live : .new(event)
    }

    func showWindow() {
        // Restore the Dock icon and app menus when coming back from menu-bar-only mode.
        if NSApp.activationPolicy() == .accessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// Menu bar › Settings: the Settings window, without the main one. Oatcake may be running in the
    /// menu bar only, out of the Dock: its Dock icon and menus come back first, as they do for its window.
    func showSettings() {
        if NSApp.activationPolicy() == .accessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        openSettingsWindow?()
    }

    private var mainWindowIsUp: Bool { NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible } }

    /// Menu bar › Stop Recording…: asks first, as the window's Stop does, and the question is asked in
    /// the window, which comes forward. A window that was closed has to be there before anything can
    /// be asked in it, so the question waits for it. If no window comes, the recording is stopped:
    /// that's what was chosen, and it mustn't carry on with you thinking it had ended.
    private func stopFromMenuBar() {
        let wasUp = mainWindowIsUp
        showWindow()
        if wasUp { return recording.confirmStop() }
        Task {
            for _ in 0..<30 where !mainWindowIsUp { try? await Task.sleep(for: .milliseconds(100)) }
            guard mainWindowIsUp else {
                await recording.stopLive()
                return
            }
            // The window is there a moment before what's in it is.
            try? await Task.sleep(for: .milliseconds(300))
            recording.confirmStop()
        }
    }

    /// New recording (⌘N, the sidebar button, the menu bar): the screen to start one, or the call already being recorded.
    func newRecording(_ event: CalendarEvent? = nil) {
        showWindow()
        selection = recording.live != nil ? .live : .new(event)
    }

    // MARK: - Status

    /// Work that closing the window shouldn't end: anything an update waits for, a model on its way
    /// down, and a read of the recordings under way (a call that has just stopped is no longer being
    /// recorded, but isn't being analysed until that read finds it).
    var hasWorkInFlight: Bool { refreshing || busyReason != nil || downloads.isDownloading }

    /// What quitting now would interrupt or lose, as a question to ask first; nil when it would do
    /// neither. Edits waiting to be saved are written before this is asked (saveEdits), so only those
    /// that couldn't be are counted. (The updater's own quit never gets here with one: it checks
    /// `whyUpdateWaits`, which covers the rest, just before it quits.)
    var quitQuestion: (title: String, text: String, ok: String)? {
        if let live = recording.live, recording.recorderFailure == nil {
            return ("Stop recording and quit?",
                    "Oatcake is recording “\(live.title)”. Quitting stops the recording. What’s been recorded so far is transcribed the next time you open Oatcake.",
                    "Stop Recording and Quit")
        }
        var doing: [String] = []
        var after: [String] = []
        if jobs.isAnalysingAny {
            doing.append("analysing a call")
            after.append("The analysis starts again the next time you open Oatcake.")
        }
        if !jobs.summarising.isEmpty {
            doing.append("writing a summary")
            after.append("A summary that isn’t finished can be written later, with Write summary in its meeting.")
        }
        if !jobs.drafting.isEmpty {
            doing.append("writing a draft for sharing")
            after.append("A draft that isn’t finished can be written later, with Draft for Sharing… in its meeting.")
        }
        if ask.running != nil {
            doing.append("answering a question")
            after.append("You can ask it again the next time you open Oatcake.")
        }
        if let importing = library.importing {
            doing.append("importing from \(importing)")
            after.append("Importing again carries on with the meetings that didn’t come in.")
        }
        // Typed, and kept nowhere that outlasts Oatcake.
        var lost: [String] = []
        if let title = notesOfCallNotRecorded { lost.append("the notes you’ve typed for “\(title)”, a call that wasn’t recorded") }
        if edits.hasFailed(in: library.meetings) { lost.append("edits that couldn’t be saved") }
        // Not while an update is under way: it said so before it started, and its quit isn't asked again.
        if updater.installing == nil, jobs.hasNamesTyped { lost.append("the names you’ve typed in Who’s who") }
        guard !doing.isEmpty || !lost.isEmpty else { return nil }
        func listed(_ items: [String]) -> String { items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items.last! : items[0] }
        let text = [doing.isEmpty ? nil : "Oatcake is \(listed(doing)).", lost.isEmpty ? nil : "Quitting loses \(listed(lost))."].compactMap { $0 } + after
        return ("Quit Oatcake?", text.joined(separator: " "), "Quit")
    }

    /// The title of the call on the live screen that couldn't be recorded, when notes have been typed
    /// for it: quitting deletes it, notes and all, as Close does.
    private var notesOfCallNotRecorded: String? {
        guard let live = recording.live, recording.recorderFailure != nil,
              recording.liveNotes[live.id]?.contains(where: { !$0.text.trimmed.isEmpty }) == true else { return nil }
        return live.title
    }

    /// Why an update has to wait, if it does.
    var busyReason: String? {
        if recording.isRecording { return "Oatcake is recording a call. Install the update after you stop." }
        if jobs.isAnalysingAny { return "Oatcake is analysing a call. Install the update when it's done." }
        if !jobs.summarising.isEmpty { return "Oatcake is writing a summary. Try again in a moment." }
        if !jobs.drafting.isEmpty { return "Oatcake is writing a draft for sharing. Try again in a moment." }
        if ask.running != nil { return "Oatcake is answering a question. Try again in a moment." }
        if library.importing != nil { return "Oatcake is importing meetings. Install the update when it's done." }
        return nil
    }

    /// The updater asks this as it starts and again just before it quits. Edits waiting to be saved are
    /// written first. Any that can't be, and notes typed for a call that wasn't recorded, would be lost,
    /// so they're reasons to wait too: unlike `busyReason`, they don't end by themselves, so closing the
    /// window doesn't wait for them (quitting asks instead).
    private func whyUpdateWaits() -> String? {
        saveEdits()
        if edits.hasFailed(in: library.meetings) { return "Oatcake couldn’t save some edits to a meeting. Choose Try again in the meeting, then install the update." }
        if let title = notesOfCallNotRecorded {
            return "Installing the update would delete the notes you’ve typed for “\(title)”, a call that wasn’t recorded. Copy them somewhere else and close the call first."
        }
        return busyReason
    }
}

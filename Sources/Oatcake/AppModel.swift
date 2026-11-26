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
    /// The meeting list (`AppModel.folder`), with no meeting open.
    case folder
    /// New recording, for a calendar event or none. Choosing the same again keeps what's been typed.
    case new(CalendarEvent?)
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
enum MeetingTab: String, CaseIterable {
    case summary, transcript, notes, draft

    /// The tab meetings open on: the one last chosen, kept from one launch to the next.
    static var last: MeetingTab {
        get { UserDefaults.standard.string(forKey: "meetingTab").flatMap(MeetingTab.init(rawValue:)) ?? .summary }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "meetingTab") }
    }
}

/// Where you were, for Back and Forward: the screen, and the folder the meeting list showed.
struct Place: Equatable {
    var selection: Selection
    var folder: String
}

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
    var showWindow: @MainActor () -> Void = {}
    var selection: @MainActor () -> Selection? = { nil }
    var select: @MainActor (Selection?) -> Void = { _ in }
    /// Back from a screen that's done with: to the meeting that was open, or the meeting list.
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
    var selection: Selection? {
        didSet {
            // Kept for the next launch: Home, To-dos or a meeting. The other screens don't last.
            let screen: String?
            switch selection {
            case .meeting(let path, _):
                lastMeeting = path
                screen = "meeting"
            case .home: screen = "home"
            case .todos: screen = "todos"
            default: screen = nil
            }
            if let screen { UserDefaults.standard.set(screen, forKey: "lastScreen") }
        }
    }
    /// The folder the middle column lists.
    var folder = "" { didSet { UserDefaults.standard.set(folder, forKey: "lastFolder") } }
    /// The meeting last open, kept while another screen shows: a recording discarded or cancelled comes back to it.
    private(set) var lastMeeting: String? { didSet { UserDefaults.standard.set(lastMeeting, forKey: "lastMeeting") } }
    private var history = History<Place>()
    var confirmation: Confirmation?
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
                              showWindow: { [unowned self] in self.showWindow() },
                              selection: { [unowned self] in self.selection },
                              select: { [unowned self] in self.selection = $0 },
                              showFolder: { [unowned self] in self.backToMeetings() })
        library.app = app
        recording.app = app
        jobs.app = app
        downloads.app = app
        calendar.app = app
        library.whenMoved = { [unowned self] from, to in self.moved(from: from, to: to) }
        // A meeting saved without checking who's who keeps voice clips in Oatcake's own folder: they go with it.
        library.whenTrashed = { [unowned self] in self.jobs.tidySavedRecordings() }
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
        let tree = library.meetings.tree()
        library.tree = tree
        library.setTodos(library.meetings.allTodos(in: tree))
        jobs.pending = Recordings.list().filter { $0.state == .recorded || $0.state == .processed }
        jobs.unchecked = Recordings.unchecked()
        restorePlace(in: tree)
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
                      busy: { [weak self] in self?.busyReason })
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
        Task {
            let (tree, pending, unchecked, todos) = await Task.detached {
                // The folder is walked once: the to-dos are read from the tree just built.
                let tree = meetings.tree()
                return (tree, Recordings.list().filter { $0.state == .recorded || $0.state == .processed }, Recordings.unchecked(),
                        meetings.allTodos(in: tree))
            }.value
            refreshing = false
            defer {
                if refreshWanted {
                    refreshWanted = false
                    refresh()
                }
            }
            // Another Meetings folder was chosen while this one was being read: its read is on its way.
            guard library.meetings === meetings else { return }
            let previous = library.tree
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
            keepPlace(previous: previous, tree: tree)
            jobs.startWaiting()
            jobs.updateBadge()
        }
    }

    /// Where Oatcake was when it last closed: the folder listed, and Home, To-dos or the meeting that
    /// was open (on the tab last chosen). One that has gone since gives way to the nearest folder, or Home.
    private func restorePlace(in tree: TreeNode) {
        let defaults = UserDefaults.standard
        folder = nearestFolder(defaults.string(forKey: "lastFolder") ?? "", in: tree)
        lastMeeting = defaults.string(forKey: "lastMeeting").flatMap { tree.find($0)?.kind == .meeting ? $0 : nil }
        // A recording picked up again has opened its live view already.
        guard selection == nil else { return }
        switch defaults.string(forKey: "lastScreen") {
        case "todos" where config.todosEnabled: selection = .todos
        case "meeting": selection = lastMeeting.map { .meeting($0) } ?? .home
        default: selection = .home
        }
    }

    /// After a new read of the Meetings folder: a folder or meeting that was there before and has gone
    /// (moved to the Trash, renamed or deleted in Finder, another Meetings folder chosen) isn't kept as
    /// if it were still there. One that isn't there yet (just saved, renamed in Oatcake) is left: the
    /// read that has it is on its way.
    private func keepPlace(previous: TreeNode?, tree: TreeNode) {
        let gone = { (path: String) in previous?.find(path) != nil && tree.find(path) == nil }
        if gone(folder) { folder = nearestFolder(folder, in: tree) }
        if let meeting = lastMeeting, gone(meeting) { lastMeeting = nil }
        if case .meeting(let path, _) = selection, gone(path) { selection = .folder }
    }

    /// Follows a link to a meeting (a to-do's, a citation in Ask, a search result…), into its folder's
    /// list. Back (⌘[) returns to where you were.
    func openMeeting(_ path: String, jump: Jump? = nil) {
        guard library.tree?.find(path)?.kind == .meeting else { return }
        if let here { history.leave(here) }
        folder = parentOf(path)
        selection = .meeting(path, jump: jump)
    }

    /// Where you are, as Back and Forward keep it: a meeting without the jump it was opened with.
    private var here: Place? {
        guard var selection else { return nil }
        if case .meeting(let path, _) = selection { selection = .meeting(path) }
        return Place(selection: selection, folder: folder)
    }

    private func stillThere(_ place: Place) -> Bool {
        switch place.selection {
        case .meeting(let path, _): library.tree?.find(path)?.kind == .meeting
        case .home: true
        case .todos: config.todosEnabled
        case .folder: library.tree?.find(place.folder)?.kind == .folder
        case .live: recording.live != nil
        case .job(let id): jobs.pending.contains { $0.id == id } || jobs.unchecked.contains { $0.id == id }
        // A New recording gone back to would be a new one.
        case .new: false
        }
    }

    var canGoBack: Bool { here.map { history.canGoBack(from: $0, where: stillThere) } ?? false }
    var canGoForward: Bool { here.map { history.canGoForward(from: $0, where: stillThere) } ?? false }

    func goBack() {
        guard let here, let place = history.goBack(from: here, where: stillThere) else { return }
        go(to: place)
    }

    func goForward() {
        guard let here, let place = history.goForward(from: here, where: stillThere) else { return }
        go(to: place)
    }

    private func go(to place: Place) {
        showWindow()
        // The folder may have gone since, though the meeting is still there.
        folder = library.tree.map { nearestFolder(place.folder, in: $0) } ?? place.folder
        selection = place.selection
    }

    /// New recording's Cancel: back to where you were before it (Home, a meeting…), as Back goes.
    func cancelNewRecording() {
        if canGoBack { goBack() } else { backToMeetings() }
    }

    /// Back from a screen that's done with (a recording discarded or cancelled): to the meeting that
    /// was open, in the list that was showing; failing that, the list's newest.
    func backToMeetings() {
        if let lastMeeting, library.tree?.find(lastMeeting)?.kind == .meeting {
            selection = .meeting(lastMeeting)
        } else {
            openFolder(folder)
        }
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
            selection = .folder
        }
    }

    /// A folder or meeting now lives at `to` (renamed or moved).
    func moved(from: String, to: String) {
        let remap = { (p: String) in remapped(p, from: from, to: to) }
        folder = remap(folder)
        lastMeeting = lastMeeting.map(remap)
        jobs.moved(remap)
        if case .meeting(let p, let jump) = selection { selection = .meeting(remap(p), jump: jump) }
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
        leave(for: recording.live != nil ? .live : .new(event))
    }

    func showWindow() {
        // Restore the Dock icon and app menus when coming back from menu-bar-only mode.
        if NSApp.activationPolicy() == .accessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        // A window in the Dock isn't visible, but it's there to bring back.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && ($0.isVisible || $0.isMiniaturized) }) {
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
        leave(for: recording.live != nil ? .live : .new(event))
    }

    /// To another screen, which Back (and New recording's Cancel) comes back from.
    private func leave(for screen: Selection) {
        if screen != selection, let here { history.leave(here) }
        selection = screen
    }

    // MARK: - Status

    /// Work that closing the window shouldn't end: anything an update waits for, a model on its way
    /// down, and a read of the recordings under way (a call that has just stopped is no longer being
    /// recorded, but isn't being analysed until that read finds it).
    var hasWorkInFlight: Bool { refreshing || busyReason != nil || downloads.isDownloading }

    /// What quitting now would interrupt, as a question to ask first; nil when it would interrupt
    /// nothing. (The updater's own quit never gets here with one: it checks `busyReason`, which
    /// covers the same things, just before it quits.)
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
        if let importing = library.importing {
            doing.append("importing from \(importing)")
            after.append("Importing again carries on with the meetings that didn’t come in.")
        }
        guard !doing.isEmpty else { return nil }
        let what = doing.count > 1 ? doing.dropLast().joined(separator: ", ") + " and " + doing.last! : doing[0]
        return ("Quit Oatcake?", "Oatcake is \(what). \(after.joined(separator: " "))", "Quit")
    }

    /// Why an update has to wait, if it does.
    var busyReason: String? {
        if recording.isRecording { return "Oatcake is recording a call. Install the update after you stop." }
        if jobs.isAnalysingAny { return "Oatcake is analysing a call. Install the update when it's done." }
        if !jobs.summarising.isEmpty { return "Oatcake is writing a summary. Try again in a moment." }
        if library.importing != nil { return "Oatcake is importing meetings. Install the update when it's done." }
        return nil
    }
}

// The app as a whole: its settings, where you are in the window, what it says to you (toasts and
// questions), and the parts that do the work, wired together here. The parts are the Meetings
// folder (Library), the call being recorded (RecordingController), recordings after the call
// (Jobs), the language model's downloads (ModelDownloads) and the calendar (CalendarController).

import AppKit
import OatcakeCore
import SwiftUI

/// What the detail pane shows.
enum Selection: Equatable {
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
    var nonce = UUID()
}

enum MeetingTab: String, CaseIterable { case summary, transcript, notes }

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
    /// Something on disk has changed: read the Meetings folder and the recordings again.
    var refresh: @MainActor () -> Void = {}
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
    /// Bumped by ⌘F and ⌥⌘F: the open meeting shows Find, the meeting list focuses its search.
    var findRequest = 0
    var searchRequest = 0
    /// File › New Folder: the sidebar asks for the new top-level folder's name. It waits here until the
    /// sidebar takes it, which is after the window has opened if it was closed.
    var wantsNewFolder = false
    var selection: Selection?
    /// The folder the middle column lists.
    var folder = ""
    var confirmation: Confirmation?
    var toastText: String?
    /// The toast showing says something went wrong: it stays longer, and goes when it's clicked.
    var toastIsError = false
    let updater = Updater()
    let ask = AskChat()
    /// Why the settings couldn't be read at launch, until it has been shown.
    private var configProblem: String?
    private var timers: [Timer] = []
    private var toastTask: Task<Void, Never>?
    /// A read of the Meetings folder is under way, and another has been asked for since it began.
    private var refreshing = false
    private var refreshWanted = false
    var openMainWindow: (() -> Void)?

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
                              refresh: { [unowned self] in self.refresh() },
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
        // Left by the Electron version: its secrets move into the Keychain, its speech models and
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
        Secrets.forgetRetired()
        // A language model left running by a copy of Oatcake that didn't get to stop it.
        ModelServer.stopLeftover()
        jobs.tidySavedRecordings()

        recording.resumeRecordings()
        library.watchMeetings()
        // The first load happens before the window shows, so it opens on your last meeting rather
        // than on whatever the sidebar selects by itself.
        library.tree = library.meetings.tree()
        if let tree = library.tree { library.setTodos(library.meetings.allTodos(in: tree)) }
        jobs.pending = Recordings.list().filter { $0.state == .recorded || $0.state == .processed }
        openLastMeeting()
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
        // Stop asks first, as the window's Stop does: the window comes forward with the question.
        recording.menuBar.stop = { [weak self] in
            self?.showWindow()
            self?.recording.confirmStop()
        }
        recording.menuBar.open = { [weak self] in self?.showWindow() }
        recording.menuBar.record = { [weak self] in self?.newRecording() }
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
            let (tree, pending, todos) = await Task.detached {
                // The folder is walked once: the to-dos are read from the tree just built.
                let tree = meetings.tree()
                return (tree, Recordings.list().filter { $0.state == .recorded || $0.state == .processed }, meetings.allTodos(in: tree))
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
            // Without animation: the sidebar's outline animates rows in when a section (Needs review)
            // appears, and leaves a stray copy of an expanded folder's selected row behind.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                self.library.tree = tree
                self.jobs.pending = pending
                self.library.setTodos(todos)
                self.library.diskVersion += 1
            }
            jobs.startWaiting()
            jobs.updateBadge()
        }
    }

    /// Opens the meeting you were last reading, or on first run the most recent one.
    private func openLastMeeting() {
        guard selection == nil, let tree = library.tree else { return }
        if let last = UserDefaults.standard.string(forKey: "lastMeeting"), tree.find(last)?.kind == .meeting {
            return openMeeting(last)
        }
        if let newest = tree.allMeetings.max(by: { (meetingDate($0) ?? .distantPast) < (meetingDate($1) ?? .distantPast) }) {
            openMeeting(newest.path)
        }
    }

    func openMeeting(_ path: String, jump: Jump? = nil) {
        guard library.tree?.find(path)?.kind == .meeting else { return }
        folder = parentOf(path)
        selection = .meeting(path, jump: jump)
        UserDefaults.standard.set(path, forKey: "lastMeeting")
    }

    /// Opens a meeting picked in the middle column, which stays as it is (all meetings, a folder, or
    /// search results) rather than switching to the meeting's own folder.
    func selectMeeting(_ path: String, jump: Jump? = nil) {
        guard library.tree?.find(path)?.kind == .meeting else { return }
        selection = .meeting(path, jump: jump)
        UserDefaults.standard.set(path, forKey: "lastMeeting")
    }

    /// ⌥⌘F: the meeting list's search box, bringing the list back first if another screen is showing.
    func searchMeetings() {
        showWindow()
        switch selection {
        case .meeting, .folder, nil: break
        default: openFolder(folder)
        }
        DispatchQueue.main.async { self.searchRequest += 1 }
    }

    func openFolder(_ path: String) {
        folder = path
        if let first = listedIn(library.tree?.find(path)).first {
            selection = .meeting(first.path)
            UserDefaults.standard.set(first.path, forKey: "lastMeeting")
        } else {
            selection = .folder(path)
        }
    }

    /// A folder or meeting now lives at `to` (renamed or moved).
    func moved(from: String, to: String) {
        let remap = { (p: String) in p == from ? to : p.hasPrefix(from + "/") ? to + p.dropFirst(from.count) : p }
        folder = remap(folder)
        jobs.moved(remap)
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
        config = saved
        do { try saved.save() } catch { toast("Couldn’t save your settings: \(error.localizedDescription)", isError: true) }
        recording.settingsChanged(saved)
    }

    /// Saves the microphone choice and switches any running recording to it.
    func setMic(_ mic: MicChoice?) {
        var c = config
        c.mic = mic
        saveConfig(c)
    }

    func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.outputDir = url.path
        do { try config.save() } catch { toast("Couldn’t save your settings, so Oatcake will be back on the old folder next time: \(error.localizedDescription)", isError: true) }
        library.open(url)
        refresh()
    }

    /// Saves (or, with "", removes) a secret. Returns why it couldn't, for Settings to show beside the field.
    @discardableResult
    func setSecret(_ name: SecretName, _ value: String) -> String? {
        let before = Secrets.get(name)
        var problem: String?
        do { try Secrets.set(name, value) } catch { problem = error.localizedDescription }
        if name == .calendar, Secrets.get(.calendar) != before { calendar.addressChanged() }
        return problem
    }

    // MARK: - Around the window

    /// A clicked reminder: New recording for its event, unless a call is already being recorded.
    func openEvent(_ event: CalendarEvent) {
        showWindow()
        selection = recording.live != nil ? .live : .new(event)
    }

    func showWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// New recording (⌘N, the sidebar button, the menu bar): the screen to start one, or the call already being recorded.
    func newRecording(_ event: CalendarEvent? = nil) {
        showWindow()
        selection = recording.live != nil ? .live : .new(event)
    }

    // MARK: - Status

    /// Work that closing the window shouldn't end: anything an update waits for, and a model on its way down.
    var hasWorkInFlight: Bool { busyReason != nil || downloads.isDownloading }

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

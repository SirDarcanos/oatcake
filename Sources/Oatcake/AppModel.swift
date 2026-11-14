// The app's state and everything the windows ask for: the Meetings folder, recordings and their
// processing, the calendar and call reminders, Ask, and updates.

import AppKit
import OatcakeCore
import SwiftUI
import UserNotifications

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

struct JobProgress: Equatable {
    var step: String
    var fraction: Double?
    var error: String?
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

/// A line typed during a call.
struct LiveLine: Identifiable, Equatable {
    let id = UUID()
    /// Seconds in when typing started; nil until then, and always for prep notes.
    var at: Double?
    var prep: Bool
    var text: String
}

/// What you've set on a Who's who screen, kept by the app so looking at something else and coming
/// back loses nothing.
struct ReviewDraft: Equatable {
    struct Voice: Equatable {
        var name: String
        /// The name was picked from the calendar invite.
        var fromInvite = false
        var mixed = false
        /// Merged into another voice (`me` for your microphone).
        var into: String?
    }
    var title: String
    /// Where the meeting will be saved, relative to the Meetings folder.
    var folder: String
    var voices: [String: Voice]
}

@MainActor @Observable
final class AppModel {
    var config: Config
    private(set) var meetings: Meetings
    var tree: TreeNode?
    /// Bumps on every change on disk, so open meetings re-read their files.
    var diskVersion = 0
    /// nil when no calendar address is set.
    var calendar: CalendarCache?
    /// The time, moved on every half minute: what Upcoming's countdowns are worked out from.
    var now = Date()
    var calendarFetching = false
    var pending: [Recording] = []
    var todoMeetings: [MeetingTodos] = []
    var progress: [String: JobProgress] = [:]
    /// Meetings whose summary is being written now, and why the last attempt failed, by path.
    var summarising = Set<String>()
    var summaryErrors: [String: String] = [:]
    /// Where each meeting being summarised lives now: it can be renamed or moved while the model writes.
    private var summaryJobs: [UUID: String] = [:]
    var reviewDrafts: [String: ReviewDraft] = [:]
    var live: Recording?
    /// The call being recorded, as it's heard: lines from the live helper, and what the helper is doing.
    var liveLines: [LiveTranscriptLine] = []
    var liveStatus = ""
    /// Bumped by ⌘F and ⌥⌘F: the open meeting shows Find, the meeting list focuses its search.
    var findRequest = 0
    var searchRequest = 0
    /// File › New Folder: the sidebar asks for the new top-level folder's name. It waits here until the
    /// sidebar takes it, which is after the window has opened if it was closed.
    var wantsNewFolder = false
    var status = RecorderStatus(state: .starting)
    /// Why the call that's "live" isn't being recorded at all: the recorder never started. The live
    /// screen stays, saying so, until it's closed.
    var recorderFailure: String?
    /// Since when the microphone, and the call audio, have had nothing in them; nil while there's sound.
    var micQuietSince: Date?
    var callQuietSince: Date?
    /// When the recording will stop by itself because the call seems to have ended, once it has said so.
    var stoppingAt: Date?
    /// Why the notes typed during the call couldn't be saved, until a save works.
    var liveNotesError: String?
    /// Meetings whose to-dos couldn't be read from the model's reply, and why, by path.
    var todoProblems: [String: String] = [:]
    var selection: Selection?
    /// The folder the middle column lists.
    var folder = ""
    var confirmation: Confirmation?
    var toastText: String?
    let updater = Updater()
    let ask = AskChat()
    /// Notes typed during each call, kept here so leaving the live view and coming back keeps them.
    var liveNotes: [String: [LiveLine]] = [:]
    var pendingEvent: CalendarEvent?
    /// How far each language model's download has got (0 to 1) while one is under way, and why the
    /// last one stopped, by model.
    var modelDownloads: [String: Double] = [:]
    var modelDownloadErrors: [String: String] = [:]
    /// Bumps when a model's file arrives or is removed, so Settings looks at the disk again.
    var modelsVersion = 0
    private var modelDownloadTasks: [String: Task<Void, Error>] = [:]

    /// Recorders running now, by recording ID.
    private var active: [String: Recording] = [:]
    private var analysing = Set<String>()
    /// The analysis helper running for each recording, and the work around it (which goes on to
    /// suggest names), so discarding a recording stops both.
    private var helpers: [String: Process] = [:]
    private var analyses: [String: Task<Void, Never>] = [:]
    private var autoStarted = Set<String>()
    private var liveHelper: Process?
    /// The recording whose live transcript helper is running or on its way up. A second helper for the
    /// same recording would say every line again.
    private var liveTranscriptFor: String?
    /// When a calling app started using the microphone, whether recording has been offered for that
    /// call, whether the recording in progress has had a calling app on the microphone, and since
    /// when it has had neither that nor any call audio.
    private var callSince: Date?
    private var callOffered = false
    private var callSeen = false
    private var callOverSince: Date?
    /// Whether a calling app has the microphone right now, as of the last look.
    private var callOnMic = false
    /// Keep recording was chosen: this recording doesn't stop by itself any more.
    private var keepsRecording = false
    /// The recording is being stopped or cancelled, so the recorder going is expected.
    private var endingLive = false
    private var micQuietSaid = false
    private var callQuietSaid = false
    /// Why the settings couldn't be read at launch, until it has been shown.
    private var configProblem: String?
    /// One at a time: two clear-ups at once could both be writing the same meeting's audio.
    private let tidying = DispatchQueue(label: "oatcake.tidy-saved", qos: .utility)
    private let menuBar = MenuBarItem()
    private var watcher: FolderWatcher?
    private var timers: [Timer] = []
    private var statusTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private var calendarFetch: (url: String, task: Task<CalendarCache, Never>)?
    private var calendarUrlFetched = ""
    private var reminded = Set<String>()
    private var notesSaveTask: Task<Void, Never>?
    var openMainWindow: (() -> Void)?

    init() {
        let (config, problem) = Config.loadWithProblem()
        self.config = config
        configProblem = problem
        meetings = Meetings(root: config.meetingsRoot)
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
        tidySavedRecordings()

        resumeRecordings()
        watchMeetings()
        // The first load happens before the window shows, so it opens on your last meeting rather
        // than on whatever the sidebar selects by itself.
        tree = meetings.tree()
        todoMeetings = meetings.allTodos()
        pending = Recordings.list().filter { $0.state == .recorded || $0.state == .processed }
        openLastMeeting()
        refresh()
        // An address set in an earlier session counts as already fetched, so this only fetches if stale.
        calendarUrlFetched = calendarAddress
        refreshCalendar()
        checkReminders()
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refreshCalendar() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.now = Date()
                self.checkReminders()
                self.updateMenuBar()
                // The language model gives its memory back after ten minutes with nothing to write.
                await ModelServer.shared.stopIfIdle(for: 600)
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                self.checkRecorder()
                self.checkCall()
            }
        })
        // Stop asks first, as the window's Stop does: the window comes forward with the question.
        menuBar.stop = { [weak self] in
            self?.showWindow()
            self?.confirmStop()
        }
        menuBar.open = { [weak self] in self?.showWindow() }
        menuBar.record = { [weak self] in self?.newRecording() }
        menuBar.openEvent = { [weak self] event in self?.openEvent(event) }
        updateMenuBar()
        updater.start(autoCheck: { [weak self] in self?.config.updateCheck ?? false },
                      busy: { [weak self] in self?.busyReason })
    }

    // MARK: - Meetings folder

    func refresh() {
        let meetings = meetings
        Task {
            let (tree, pending, todos) = await Task.detached {
                (meetings.tree(), Recordings.list().filter { $0.state == .recorded || $0.state == .processed }, meetings.allTodos())
            }.value
            // Without animation: the sidebar's outline animates rows in when a section (Needs review)
            // appears, and leaves a stray copy of an expanded folder's selected row behind.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                self.tree = tree
                self.pending = pending
                self.todoMeetings = todos
                self.diskVersion += 1
            }
            // Recordings waiting to be processed start straight away, in the background.
            for rec in pending where rec.state == .recorded && !autoStarted.contains(rec.id) {
                autoStarted.insert(rec.id)
                analyse(rec.id)
            }
            updateBadge()
        }
    }

    /// Opens the meeting you were last reading, or on first run the most recent one.
    private func openLastMeeting() {
        guard selection == nil, let tree else { return }
        if let last = UserDefaults.standard.string(forKey: "lastMeeting"), tree.find(last)?.kind == .meeting {
            return openMeeting(last)
        }
        if let newest = tree.allMeetings.max(by: { (meetingDate($0) ?? .distantPast) < (meetingDate($1) ?? .distantPast) }) {
            openMeeting(newest.path)
        }
    }

    // Keep the sidebar in step with Finder.
    private func watchMeetings() {
        try? FileManager.default.createDirectory(at: meetings.root, withIntermediateDirectories: true)
        watcher = FolderWatcher(meetings.root) { [weak self] in self?.refresh() }
    }

    func openMeeting(_ path: String, jump: Jump? = nil) {
        guard tree?.find(path)?.kind == .meeting else { return }
        folder = parentOf(path)
        selection = .meeting(path, jump: jump)
        UserDefaults.standard.set(path, forKey: "lastMeeting")
    }

    /// Opens a meeting picked in the middle column, which stays as it is (all meetings, a folder, or
    /// search results) rather than switching to the meeting's own folder.
    func selectMeeting(_ path: String, jump: Jump? = nil) {
        guard tree?.find(path)?.kind == .meeting else { return }
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
        if let first = listedIn(tree?.find(path)).first {
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
        // A summary on its way follows the meeting to where it is now.
        summarising = Set(summarising.map(remap))
        summaryJobs = summaryJobs.mapValues(remap)
        summaryErrors = Dictionary(summaryErrors.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        todoProblems = Dictionary(todoProblems.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        switch selection {
        case .meeting(let p, let jump): selection = .meeting(remap(p), jump: jump)
        case .folder(let p): selection = .folder(remap(p))
        default: break
        }
        refresh()
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

    func move(_ path: String, into target: String) {
        guard path != target, !target.hasPrefix(path + "/"), parentOf(path) != target else { return }
        attempt {
            moved(from: path, to: try meetings.move(path, into: target))
            toast("Moved to \(folderPath(target))")
        }
    }

    @discardableResult
    func createFolder(in parent: String, named name: String) -> String? {
        var made: String?
        attempt { made = try meetings.createFolder(in: parent, named: name) }
        refresh()
        return made
    }

    /// Moves meetings or folders to the Trash. One that can't be moved stops the rest, and the toast
    /// says how many went before it and why.
    func trash(_ nodes: [TreeNode]) {
        defer { refresh() }
        var moved = 0
        do {
            for node in nodes {
                try meetings.trash(node.path)
                moved += 1
            }
        } catch {
            toast(nodes.count == 1 ? error.localizedDescription
                                   : "Moved \(moved) of \(nodes.count) meetings to the Trash — \(error.localizedDescription)")
            return
        }
        if nodes.count == 1, let node = nodes.first {
            toast("Moved “\(node.kind == .meeting ? meetingTitle(node) : node.name)” to the Trash")
        } else if !nodes.isEmpty {
            toast("Moved \(nodes.count) meetings to the Trash")
        }
    }

    func reveal(_ path: String) { reveal([path]) }

    func reveal(_ paths: [String]) {
        let urls = paths.compactMap { try? resolveInside(meetings.root, $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func readMeeting(_ path: String) throws -> MeetingFiles { try meetings.read(path) }

    func writeMeetingFile(_ path: String, _ file: MeetingFile, _ content: String) throws {
        try meetings.write(path, file, content)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { toast(error.localizedDescription) }
    }

    func toast(_ text: String) {
        withAnimation { toastText = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { withAnimation { toastText = nil } }
        }
    }

    // MARK: - Settings

    func saveConfig(_ new: Config) {
        // The Meetings folder only changes through the folder picker.
        var saved = new
        saved.outputDir = config.outputDir
        // A control that sets what it already shows (a picker redrawn, a field losing focus) changes nothing.
        guard saved != config else { return }
        config = saved
        try? saved.save()
        for rec in active.values { try? Recordings.setMic(rec.dir, uid: saved.mic?.uid) }
        // The live transcript follows its switch straight away, mid-call too.
        if let live {
            if !saved.liveTranscript { stopLiveTranscript() } else if liveHelper == nil { startLiveTranscript(live) }
        }
        updateMenuBar()
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
        try? config.save()
        meetings = Meetings(root: url)
        watchMeetings()
        refresh()
    }

    /// What's being imported ("Granola", "Quill"), if anything. Kept here rather than in the Settings
    /// row, which starts afresh if its window is closed and opened again: one import at a time.
    var importing: String?

    /// Settings › Import from Granola: pick the export, import it, and show the new meetings.
    func importGranolaExport(progress: @escaping ImportProgress) async throws -> ImportResult? {
        let panel = NSOpenPanel()
        panel.title = "Import from Granola"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.zip, .commaSeparatedText]
        guard importing == nil, panel.runModal() == .OK, let url = panel.url else { return nil }
        importing = "Granola"
        defer { importing = nil }
        let root = meetings.root
        progress(0, 0)
        let result = try await Task.detached { try importGranola(url, into: root, progress: progress) }.value
        refresh()
        return result
    }

    /// Settings › Import from Quill: pick Quill's backup, import it, and show the new meetings.
    func importQuillBackup(progress: @escaping ImportProgress) async throws -> ImportResult? {
        let panel = NSOpenPanel()
        panel.title = "Import from Quill"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.zip]
        guard importing == nil, panel.runModal() == .OK, let url = panel.url else { return nil }
        importing = "Quill"
        defer { importing = nil }
        let root = meetings.root, me = config.myName
        progress(0, 0)
        let result = try await Task.detached { try importQuill(url, into: root, me: me, progress: progress) }.value
        refresh()
        return result
    }

    func setSecret(_ name: SecretName, _ value: String) {
        let before = Secrets.get(name)
        attempt { try Secrets.set(name, value) }
        if name == .calendar, Secrets.get(.calendar) != before { calendarChanged() }
    }

    // MARK: - Calendar

    /// The calendar's private iCal address. "" = no calendar.
    private var calendarAddress: String { Secrets.get(.calendar).trimmed }

    /// Fetched at most once an hour (checked every 5 minutes, so a Mac that slept catches up),
    /// straight away when its address changes, and whenever the refresh button is pressed.
    func refreshCalendar(force: Bool = false) {
        let url = calendarAddress
        guard !url.isEmpty else {
            calendar = nil
            return
        }
        // Joins a fetch already running for this address.
        if calendarFetch?.url == url { return }
        let cached = CalendarCache.load()
        if calendar == nil { calendar = cached }
        if !force, url == calendarUrlFetched, !cached.isStale() { return }
        calendarFetching = true
        let task = Task { await fetchCalendar(url) }
        calendarFetch = (url, task)
        Task {
            let cache = await task.value
            // The address changed meanwhile: an older fetch's result is thrown away.
            guard calendarFetch?.url == url else { return }
            calendarFetch = nil
            calendarFetching = false
            calendarUrlFetched = url
            try? cache.save()
            calendar = cache
            updateMenuBar()
        }
    }

    /// A new (or no) calendar address: forget the old one's events and fetch the new one.
    private func calendarChanged() {
        calendarFetch = nil
        calendarFetching = false
        calendarUrlFetched = ""
        try? FileManager.default.removeItem(at: Paths.calendar)
        calendar = nil
        if !calendarAddress.isEmpty { refreshCalendar(force: true) }
    }

    // Call reminders: 5 minutes before each call, a notification whose button opens the call and
    // starts recording it. Clicking the notification itself opens New recording for the event.
    private func checkReminders() {
        guard config.callReminders, let calendar else { return }
        let now = Date()
        for event in calendar.events where !event.allDay && !reminded.contains(event.id) {
            let until = event.startDate.timeIntervalSince(now)
            // In the five minutes before it starts (or the first minute after, if the Mac was asleep).
            guard until <= 300, until >= -60 else { continue }
            reminded.insert(event.id)
            Reminders.show(event)
        }
    }

    /// Shows a reminder for the next timed event straight away, for checking notifications work.
    func testReminder() -> String? {
        guard let next = calendar?.events.first(where: { !$0.allDay && $0.endDate > Date() }) else { return nil }
        Reminders.show(next)
        return next.title
    }

    /// A clicked reminder: New recording for its event, unless a call is already being recorded.
    func openEvent(_ event: CalendarEvent) {
        showWindow()
        selection = live != nil ? .live : .new(event)
    }

    /// Opens the call's link, starts recording it, and brings Oatcake forward on the live notes.
    func startFromEvent(_ event: CalendarEvent) {
        if let link = event.callLink, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        // Already recording: go back to that recording rather than start a second.
        if active.isEmpty {
            do {
                let folder = try meetings.folderForEvent(title: event.title, recurring: event.seriesId != nil)
                try startRecording(title: event.title, folder: folder, options: startOptions(event))
            } catch {
                // Said in Oatcake's window and as a notification: the call's own window is in front by now,
                // and an alert would sit behind it while the call went unrecorded.
                showWindow()
                toast(error.localizedDescription)
                Reminders.say("Oatcake couldn’t start recording", error.localizedDescription, id: "start-failed")
                return
            }
        }
        // After the browser has opened the call, so Oatcake ends up in front for the notes.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            showWindow()
            selection = .live
        }
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

    // MARK: - Recording

    /// New recording (⌘N, the sidebar button, the menu bar): the screen to start one, or the call already being recorded.
    func newRecording(_ event: CalendarEvent? = nil) {
        showWindow()
        selection = live != nil ? .live : .new(event)
    }

    /// A recording started straight from a calendar event carries the event, any prep notes written
    /// for it on New recording, and who else is invited.
    private func startOptions(_ event: CalendarEvent) -> Recordings.StartOptions {
        .init(eventId: event.id, prep: PrepNotes.load(event.id), attendees: otherAttendees(event, myName: config.myName).map(attendeeName))
    }

    /// The link to the call being recorded, when it was started from a calendar event that has one.
    var liveCallLink: URL? {
        guard let id = live?.eventId, let link = calendar?.events.first(where: { $0.id == id })?.callLink else { return nil }
        return URL(string: link)
    }

    func startRecording(title: String, folder: String, options: Recordings.StartOptions) throws {
        // One call at a time: a second recorder would capture the same audio.
        guard active.isEmpty else { throw OatcakeError("Oatcake is already recording a call. Stop it first.") }
        let rec = try Recordings.start(title: title, folder: folder, micUid: config.mic?.uid, options: options)
        active[rec.id] = rec
        // The prep is in the call's notes now.
        if !options.prep.isEmpty { try? PrepNotes.save(options.eventId, []) }
        goLive(rec)
    }

    private func goLive(_ rec: Recording) {
        live = rec
        status = RecorderStatus(state: .starting)
        selection = .live
        callSeen = false
        callOverSince = nil
        resetLiveState()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let live = self.live else { return }
                self.status = Recordings.status(live)
                self.trackSilence()
                self.updateMenuBar()
            }
        }
        startLiveTranscript(rec)
        updateMenuBar()
        // The language model is fetched while the first call is recorded, to be there when it ends.
        if let chosenModel, !LocalModels.isDownloaded(chosenModel) { downloadModel(chosenModel) }
    }

    /// Recordings left from an earlier run: a recorder still going is picked up again; a dead one is finished off.
    private func resumeRecordings() {
        for rec in Recordings.list() where rec.state == .recording {
            if Recordings.isRunning(rec) {
                // This copy of Oatcake is the one looking after it now.
                Recordings.adopt(rec)
                active[rec.id] = rec
                goLive(rec)
            } else {
                Recordings.finishInterrupted(rec)
            }
        }
    }

    /// Asks the recorder to finish and waits for its meta.json; keeps whatever audio it captured if it
    /// had already stopped. A recorder that hasn't finished within five seconds (stuck on an audio
    /// device, say) is stopped outright, so the recording always goes on to be processed.
    private func stopRecorder(_ rec: Recording) async {
        Recordings.stop(rec)
        let finished = { FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent(RecorderFile.meta).path) }
        for _ in 0..<50 where !finished() && Recordings.isRunning(rec) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !finished(), Recordings.isRunning(rec) {
            Recordings.kill(rec)
            for _ in 0..<10 where Recordings.isRunning(rec) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        Recordings.finishInterrupted(rec)
        active.removeValue(forKey: rec.id)
    }

    private func endLive() {
        stopLiveTranscript()
        live = nil
        statusTimer?.invalidate()
        statusTimer = nil
        status = RecorderStatus(state: .starting)
        resetLiveState()
        updateMenuBar()
    }

    /// What's only true of one recording: a new one starts without it, and it goes when one ends.
    private func resetLiveState() {
        recorderFailure = nil
        liveNotesError = nil
        micQuietSince = nil
        callQuietSince = nil
        micQuietSaid = false
        callQuietSaid = false
        keepsRecording = false
        withdrawStopWarning()
    }

    /// The call is over: on to processing it. If you were on its notes you go to its progress;
    /// anywhere else, you stay there.
    private func liveEnded(_ rec: Recording, watching: Bool) {
        endLive()
        progress[rec.id] = JobProgress(step: "Starting")
        if watching || selection == .live { selection = .job(rec.id) }
        refresh()
    }

    /**
     * Every couple of seconds while a call is live: is the recorder still there? It stops by itself
     * when the disk fills or Oatcake has been gone a while, it can crash, and it can fail to start
     * (no microphone permission). Each of those is said, in Oatcake and as a notification, because
     * you're probably looking at the call and not at Oatcake.
     */
    private func checkRecorder() {
        guard let rec = live, !endingLive, recorderFailure == nil, !Recordings.isRunning(rec) else { return }
        let status = Recordings.status(rec)
        let finished = FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent(RecorderFile.meta).path)
        if finished || Recordings.hasAudio(rec) {
            let watching = selection == .live
            saveLiveNotes(rec.id)
            // Without a meta.json it went mid-recording: one is written from the audio that's there.
            Recordings.finishInterrupted(rec)
            active.removeValue(forKey: rec.id)
            liveEnded(rec, watching: watching)
            if finished {
                Reminders.say("Recording stopped", status.error ?? "The recorder stopped by itself. Oatcake is transcribing “\(rec.title)”.", id: "recorder-stopped")
                toast("The recording stopped")
            } else {
                Reminders.say("Recording stopped unexpectedly",
                              "The recorder quit part-way through “\(rec.title)”. What it captured is being transcribed. Start a new recording to carry on with the call.",
                              id: "recorder-stopped")
                toast("The recording stopped unexpectedly")
            }
            return
        }
        // Nothing was recorded. A recorder still on its way up isn't running yet either, so only a
        // status that has moved on, or a quarter of a minute of nothing, counts as not having started.
        guard status.state != .starting || Date().timeIntervalSince(rec.startedAt) > 15 else { return }
        let why = status.state == .error ? status.error ?? "The recorder stopped." : "The recorder didn’t start."
        recorderFailure = why
        stopLiveTranscript()
        updateMenuBar()
        Reminders.say("Oatcake couldn’t start recording", why, id: "recorder-failed")
    }

    /// Silence: a working mic always picks up some room noise, and true silence means nothing arrives.
    /// After half a minute of it there's a notification, once for each quiet spell; the live screen
    /// says so too.
    private func trackSilence() {
        guard status.state == .recording, recorderFailure == nil else { return }
        let now = Date()
        let micQuiet = status.micDevice != nil && (status.micLevel ?? 0) < 0.001
        let callQuiet = (status.systemLevel ?? 0) < 0.001
        let mic = micQuiet ? (micQuietSince ?? now) : nil
        let call = callQuiet ? (callQuietSince ?? now) : nil
        if mic != micQuietSince { micQuietSince = mic }
        if call != callQuietSince { callQuietSince = call }
        if !micQuiet { micQuietSaid = false }
        if !callQuiet { callQuietSaid = false }
        if let mic, now.timeIntervalSince(mic) >= 30, !micQuietSaid {
            micQuietSaid = true
            Reminders.say("Your microphone has been silent for 30 seconds", "Check it isn’t muted, or pick another microphone in Oatcake.", id: "mic-quiet")
        }
        // Only while a calling app has the microphone: dictating notes on your own, there is no call audio to miss.
        if let call, now.timeIntervalSince(call) >= 30, !callQuietSaid, callOnMic {
            callQuietSaid = true
            Reminders.say("No call audio for 30 seconds",
                          "If people are talking, allow OatcakeRecorder in System Settings › Privacy & Security › Screen & System Audio Recording.", id: "call-quiet")
        }
    }

    func confirmStop() {
        confirmation = Confirmation(
            title: "Stop recording?",
            text: "Oatcake will transcribe the call and ask you to check who’s who. You can’t add more to this recording afterwards.",
            ok: "Stop recording", cancel: "Keep recording") { [self] in await stopLive() }
    }

    /// Stops the call being recorded and starts processing it. If you're on its notes you go to its
    /// progress; anywhere else, you stay there.
    func stopLive() async {
        guard let rec = live, !endingLive else { return }
        endingLive = true
        defer { endingLive = false }
        let watching = selection == .live
        saveLiveNotes(rec.id)
        await stopRecorder(rec)
        liveEnded(rec, watching: watching)
    }

    /// Cancel before any audio arrived (or Close, when the recorder never started): stop the recorder
    /// and throw the recording away.
    func cancelRecording(hasNotes: Bool) {
        let cancel = { [self] in
            guard let rec = live, !endingLive else { return }
            endingLive = true
            defer { endingLive = false }
            await stopRecorder(rec)
            try Recordings.discard(rec.id)
            liveNotes.removeValue(forKey: rec.id)
            endLive()
            openFolder(folder)
            toast("Recording cancelled")
            refresh()
        }
        if !hasNotes {
            Task { do { try await cancel() } catch { toast(error.localizedDescription) } }
            return
        }
        confirmation = Confirmation(title: "Cancel this recording?",
                                    text: "Nothing has been recorded yet. The notes you’ve typed for it will be deleted.",
                                    ok: "Cancel recording", cancel: "Keep waiting", action: cancel)
    }

    /// Never leave the recorder (or the language model) running behind a closed app.
    func stopAllRecorders() {
        if let live { saveLiveNotes(live.id) }
        stopLiveTranscript()
        for rec in active.values { Recordings.stop(rec) }
        ModelServer.stopLeftover()
    }

    var isRecording: Bool { !active.isEmpty }

    func saveLiveNotes(_ id: String) {
        guard let lines = liveNotes[id] else { return }
        do {
            try Recordings.saveNotes(id, lines.filter { !$0.text.trimmed.isEmpty }.map { Note(at: $0.prep ? nil : $0.at ?? 0, text: $0.text.trimmed) })
            if live?.id == id, liveNotesError != nil { liveNotesError = nil }
        } catch {
            // Said on the live screen until a save works: notes that aren't on disk are lost if Oatcake goes.
            if live?.id == id { liveNotesError = "Your notes couldn’t be saved: \(error.localizedDescription)" }
        }
    }

    /// Saved 600 ms after the last keystroke.
    func liveNotesChanged(_ id: String) {
        notesSaveTask?.cancel()
        notesSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { saveLiveNotes(id) }
        }
    }

    // MARK: - Calls

    /// Every couple of seconds: is a calling app using the microphone? A call that starts while
    /// nothing is being recorded gets an offer to record it. A recording that has had a calling
    /// app on the microphone, once that app has let go and the call audio has been quiet for a
    /// quarter of a minute, says the call seems to have ended and stops half a minute after that,
    /// unless you choose Keep recording or the call comes back. Music still playing, or a call
    /// you're only muted on, keeps it going.
    private func checkCall() {
        guard config.callNotice || live != nil else { return }
        let apps = CallDetector.appsOnCall()
        callOnMic = !apps.isEmpty
        let now = Date()
        guard !apps.isEmpty else {
            callSince = nil
            guard live != nil, callSeen, config.autoStop, !keepsRecording, recorderFailure == nil,
                  status.state == .recording, (status.systemLevel ?? 0) < 0.001 else {
                callOverSince = nil
                withdrawStopWarning()
                return
            }
            callOverSince = callOverSince ?? now
            if let stoppingAt {
                if now >= stoppingAt { callEnded() }
            } else if now.timeIntervalSince(callOverSince!) >= 15 {
                stoppingAt = now.addingTimeInterval(30)
                Reminders.warnOfStop()
            }
            return
        }
        callOverSince = nil
        withdrawStopWarning()
        if callSince == nil {
            callSince = now
            callOffered = false
        }
        if live != nil {
            callSeen = true
        } else if config.callNotice, !callOffered, now.timeIntervalSince(callSince!) >= 4 {
            callOffered = true
            Reminders.offerRecording(app: apps[0], event: currentEvent)
        }
    }

    /// The call came back, or the warning has done its job: nothing is about to stop.
    private func withdrawStopWarning() {
        guard stoppingAt != nil else { return }
        stoppingAt = nil
        Reminders.withdrawStopWarning()
    }

    /// Keep recording, from the warning: this recording carries on until you stop it yourself.
    func keepRecording() {
        keepsRecording = true
        callOverSince = nil
        withdrawStopWarning()
    }

    private func callEnded() {
        guard let rec = live else { return }
        callOverSince = nil
        withdrawStopWarning()
        Task {
            await stopLive()
            Reminders.stopped(rec.title)
            toast("The call ended, so recording stopped")
        }
    }

    /// The calendar event happening now (or starting within ten minutes), if any.
    var currentEvent: CalendarEvent? {
        let now = Date()
        return calendar?.events.first { !$0.allDay && $0.startDate.addingTimeInterval(-600) <= now && $0.endDate > now }
    }

    /// From the "On a call?" notification: record it, under the calendar event happening now if there is one.
    func recordCall() {
        showWindow()
        guard active.isEmpty else { return selection = .live }
        do {
            if let event = currentEvent {
                let folder = try meetings.folderForEvent(title: event.title, recurring: event.seriesId != nil)
                try startRecording(title: event.title, folder: folder, options: startOptions(event))
            } else {
                try startRecording(title: "Call", folder: "", options: .init())
            }
        } catch {
            toast(error.localizedDescription)
        }
    }

    // MARK: - Live transcript

    private func startLiveTranscript(_ rec: Recording) {
        // Asked for again while the helper is still on its way up (settings saved just after the call
        // started, say): one is enough.
        guard liveTranscriptFor != rec.id else { return }
        liveLines = []
        liveStatus = ""
        guard config.liveTranscript, liveHelper == nil else { return }
        liveTranscriptFor = rec.id
        liveStatus = "Starting"
        Task {
            _ = try? await ChildProcess.run(Bundle.main.executableURL!, ["--live", rec.dir.path], onStart: { process in
                Task { @MainActor in
                    // The call may have ended (or the switch been turned off) before the helper got going.
                    if self.live?.id == rec.id, self.liveTranscriptFor == rec.id, self.config.liveTranscript { self.liveHelper = process } else { process.terminate() }
                }
            }, onLine: { line in
                guard let event = try? JSONDecoder().decode(LiveEvent.self, from: Data(line.utf8)) else { return }
                Task { @MainActor in
                    guard self.live?.id == rec.id else { return }
                    if let line = event.line { self.liveLines.append(line) }
                    if let status = event.status { self.liveStatus = status }
                    if let error = event.error { self.liveStatus = "The live transcript stopped: \(error)" }
                }
            })
        }
    }

    private func stopLiveTranscript() {
        liveHelper?.terminate()
        liveHelper = nil
        liveTranscriptFor = nil
    }

    // MARK: - Menu bar

    /// The menu bar shows the call being recorded (with Stop) or, with a calendar connected and the
    /// setting on, the time until the next call.
    var showsNextCallInMenuBar: Bool { config.menuBarNextCall && calendar != nil }

    func updateMenuBar() {
        // A call that couldn't be recorded isn't shown as one that is.
        if let live, recorderFailure == nil {
            menuBar.show(.recording(title: live.title, elapsed: status.state == .recording ? status.elapsed ?? 0 : nil))
        } else if showsNextCallInMenuBar {
            let now = Date()
            menuBar.show(.upcoming((calendar?.events ?? []).filter { !$0.allDay && $0.endDate > now }))
        } else {
            menuBar.hide()
        }
    }

    // MARK: - Processing

    func analyse(_ id: String) {
        guard let rec = Recordings.get(id), !analysing.contains(id) else { return }
        analysing.insert(id)
        progress[id] = JobProgress(step: progress[id]?.step ?? "Starting")
        analyses[id] = Task {
            // Steps arrive as they happen; the outcome is read from the full output once it exits.
            let result = try? await ChildProcess.run(Bundle.main.executableURL!, ["--analyse", rec.dir.path], onStart: { process in
                Task { @MainActor in self.helpers[id] = process }
            }, onLine: { line in
                guard let p = try? JSONDecoder().decode(AnalysisProgress.self, from: Data(line.utf8)), p.step != nil else { return }
                Task { @MainActor in self.apply(id, p) }
            })
            helpers.removeValue(forKey: id)
            var outcome = (result?.stdout ?? "").split(separator: "\n").reversed()
                .compactMap { try? JSONDecoder().decode(AnalysisProgress.self, from: Data($0.utf8)) }
                .first { $0.done == true || $0.error != nil }
            if outcome == nil {
                if result?.status == 0, FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent("analysis.json").path) {
                    outcome = AnalysisProgress(done: true)
                } else {
                    let detail = result.map { $0.stderr.trimmed.isEmpty ? "" : ": " + String($0.stderr.trimmed.suffix(300)) } ?? ""
                    outcome = AnalysisProgress(error: "Analysis stopped (code \(result?.status ?? -1))\(detail)")
                }
            }
            // Step 5, here rather than in the helper: the language model is the app's to run. A model
            // that's still downloading isn't waited for; the names can be typed.
            if outcome?.done == true, Recordings.get(id) != nil, !Task.isCancelled, hasUnnamedVoices(rec.dir) {
                progress[id] = JobProgress(step: analysisSteps[4])
                if let chosenModel, !LocalModels.isDownloaded(chosenModel) { downloadModel(chosenModel) }
                await suggestNames(rec.dir, config: config)
            }
            analysing.remove(id)
            analyses.removeValue(forKey: id)
            // Discarded while it ran: nothing to report.
            guard Recordings.get(id) != nil else {
                progress.removeValue(forKey: id)
                return
            }
            if let outcome { apply(id, outcome) }
        }
    }

    /// Whether a recording is still being worked on (its review waits until it isn't).
    func isAnalysing(_ id: String) -> Bool { analysing.contains(id) }

    private func apply(_ id: String, _ p: AnalysisProgress) {
        if p.done == true {
            progress.removeValue(forKey: id)
            refresh()
        } else if let error = p.error {
            progress[id] = JobProgress(step: progress[id]?.step ?? "Starting", error: error)
        } else if let step = p.step {
            progress[id] = JobProgress(step: step, fraction: p.fraction)
        }
        updateBadge()
    }

    func retry(_ rec: Recording) {
        progress[rec.id] = JobProgress(step: "Starting")
        analyse(rec.id)
    }

    func discard(_ rec: Recording) {
        confirmation = Confirmation(title: "Discard this recording?",
                                    text: "The audio, transcript and your notes will be deleted. This can’t be undone.",
                                    ok: "Discard", cancel: "Cancel") { [self] in
            // A helper still analysing it would write its transcript and clips back after the folder had gone.
            helpers.removeValue(forKey: rec.id)?.terminate()
            analyses.removeValue(forKey: rec.id)?.cancel()
            try Recordings.discard(rec.id)
            reviewDrafts.removeValue(forKey: rec.id)
            progress.removeValue(forKey: rec.id)
            openFolder(folder)
            toast("Recording discarded")
            refresh()
        }
    }

    /// Saves a reviewed recording as a meeting and starts writing its summary. Returns the meeting's path.
    func saveRecording(_ rec: Recording, decisions: [String: Decision], folder: String, title: String) throws -> String {
        let path = try saveMeeting(config, rec, decisions: decisions, folder: folder, title: title)
        reviewDrafts.removeValue(forKey: rec.id)
        writeSummary(path)
        tidySavedRecordings()
        return path
    }

    /// A saved recording's working folder has done its job: it goes, in the background, with any
    /// audio that was kept moved into the meeting first. Also run at launch, for folders left by
    /// earlier versions (which kept them) or by a copy of Oatcake that quit before it got to this.
    private func tidySavedRecordings() {
        let root = config.meetingsRoot
        tidying.async { Recordings.tidySaved(meetingsRoot: root) }
    }

    /// Writes a saved meeting's summary and to-dos in the background: after every save, and from
    /// Write summary when an earlier attempt couldn't reach the model.
    func writeSummary(_ path: String) {
        guard !summarising.contains(path) else { return }
        summarising.insert(path)
        summaryErrors.removeValue(forKey: path)
        todoProblems.removeValue(forKey: path)
        let job = UUID()
        summaryJobs[job] = path
        let config = config
        Task {
            do {
                try await ensureModel()
                // Where the meeting is now: it may have been renamed or moved while the model downloaded.
                let draft = try await OatcakeCore.draftSummary(config, meeting: summaryJobs[job] ?? path)
                try OatcakeCore.writeSummary(draft, config: config, meeting: summaryJobs[job] ?? path)
                // The summary is there, but its to-dos couldn't be read from what the model sent.
                if let problem = draft.todoProblem { todoProblems[summaryJobs[job] ?? path] = problem }
            } catch {
                summaryErrors[summaryJobs[job] ?? path] = error.localizedDescription
            }
            summarising.remove(summaryJobs[job] ?? path)
            summaryJobs.removeValue(forKey: job)
            refresh()
        }
    }

    // MARK: - Language model

    /// The model chosen in Settings, when it's one Oatcake downloads and runs itself.
    var chosenModel: LocalModel? { LocalModels.find(config.llm.model) }

    /// "Downloading the language model: 42% of 5.0 GB", while the chosen one is on its way.
    var modelDownloadStatus: String? {
        guard let chosenModel, let fraction = modelDownloads[chosenModel.id] else { return nil }
        return "Downloading the language model: \(Int(fraction * 100))% of \(chosenModel.downloadSize)"
    }

    /// Starts downloading a model, or joins the download already under way.
    @discardableResult
    func downloadModel(_ model: LocalModel) -> Task<Void, Error> {
        if let task = modelDownloadTasks[model.id] { return task }
        modelDownloadErrors.removeValue(forKey: model.id)
        modelDownloads[model.id] = 0
        let task = Task {
            defer {
                modelDownloadTasks.removeValue(forKey: model.id)
                modelDownloads.removeValue(forKey: model.id)
                modelsVersion += 1
            }
            do {
                try await ModelDownload.fetch(model) { fraction in
                    Task { @MainActor in
                        if self.modelDownloadTasks[model.id] != nil { self.modelDownloads[model.id] = fraction }
                    }
                }
            } catch {
                if !isCancellation(error) { modelDownloadErrors[model.id] = error.localizedDescription }
                throw error
            }
        }
        modelDownloadTasks[model.id] = task
        return task
    }

    func stopModelDownload(_ model: LocalModel) { modelDownloadTasks[model.id]?.cancel() }

    /// Deletes a model's file, stopping its download or the model itself first.
    func removeModel(_ model: LocalModel) {
        let download = modelDownloadTasks[model.id]
        download?.cancel()
        Task {
            _ = try? await download?.value
            await ModelServer.shared.stop()
            LocalModels.remove(model)
            modelsVersion += 1
        }
    }

    /// Waits for the chosen model to be on this Mac, downloading it if it isn't. A server of your
    /// own needs nothing.
    func ensureModel() async throws {
        guard let chosenModel, !LocalModels.isDownloaded(chosenModel) else { return }
        let download = downloadModel(chosenModel)
        // Looked at again every so often, so that whatever is waiting (a question, say) can be
        // stopped without stopping the download.
        while modelDownloadTasks[chosenModel.id] != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
        }
        do {
            try await download.value
        } catch where isCancellation(error) {
            // The download was stopped (in Settings), not what was waiting for it.
            throw OatcakeError(modelNotDownloadedMessage)
        }
    }

    // MARK: - Status

    struct Job: Identifiable {
        enum Status { case processing, review, failed }
        var rec: Recording
        var status: Status
        var step: Int
        var id: String { rec.id }
    }

    var jobs: [Job] {
        pending.sorted { $0.startedAt > $1.startedAt }.map { rec in
            let p = progress[rec.id]
            return Job(rec: rec, status: p?.error != nil ? .failed : rec.state == .processed && !analysing.contains(rec.id) ? .review : .processing,
                       step: stepNumber(p?.step ?? ""))
        }
    }

    /// The Dock badge counts what's waiting for you: recordings to review, or that failed.
    private func updateBadge() {
        let waiting = jobs.filter { $0.status != .processing }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    var todoCounts: (open: Int, overdue: Int) {
        let items = allTodoItems(todoMeetings)
        return (items.filter { !$0.todo.done }.count, items.filter { $0.isOverdue() }.count)
    }

    /// Work that closing the window shouldn't end: anything an update waits for, and a model on its way down.
    var hasWorkInFlight: Bool { busyReason != nil || !modelDownloadTasks.isEmpty }

    /// What quitting now would interrupt, as a question to ask first; nil when it would interrupt
    /// nothing. (The updater's own quit never gets here with one: it checks `busyReason`, which
    /// covers the same things, just before it quits.)
    var quitQuestion: (title: String, text: String, ok: String)? {
        if let live, recorderFailure == nil {
            return ("Stop recording and quit?",
                    "Oatcake is recording “\(live.title)”. Quitting stops the recording. What’s been recorded so far is transcribed the next time you open Oatcake.",
                    "Stop Recording and Quit")
        }
        var doing: [String] = []
        var after: [String] = []
        if !analysing.isEmpty {
            doing.append("analysing a call")
            after.append("The analysis starts again the next time you open Oatcake.")
        }
        if !summarising.isEmpty {
            doing.append("writing a summary")
            after.append("A summary that isn’t finished can be written later, with Write summary in its meeting.")
        }
        if let importing {
            doing.append("importing from \(importing)")
            after.append("Importing again carries on with the meetings that didn’t come in.")
        }
        guard !doing.isEmpty else { return nil }
        let what = doing.count > 1 ? doing.dropLast().joined(separator: ", ") + " and " + doing.last! : doing[0]
        return ("Quit Oatcake?", "Oatcake is \(what). \(after.joined(separator: " "))", "Quit")
    }

    /// Why an update has to wait, if it does.
    var busyReason: String? {
        if !active.isEmpty { return "Oatcake is recording a call. Install the update after you stop." }
        if !analysing.isEmpty { return "Oatcake is analysing a call. Install the update when it's done." }
        if !summarising.isEmpty { return "Oatcake is writing a summary. Try again in a moment." }
        if importing != nil { return "Oatcake is importing meetings. Install the update when it's done." }
        return nil
    }
}

/// Step 1–5 for a progress message; downloads and model loading count as step 1.
func stepNumber(_ step: String) -> Int { max(1, (analysisSteps.firstIndex(of: step) ?? -1) + 1) }

/// Calls back (debounced) whenever anything under a folder changes.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(_ url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Call reminders through Notification Center, with one button.
enum Reminders {
    static let category = "call-reminder"
    static let startAction = "start"

    static let callCategory = "call-noticed"
    static let recordAction = "record"

    static let stopCategory = "call-ending"
    static let keepAction = "keep"

    static func register() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: startAction, title: "Open call and start note taking", options: [.foreground])
        let record = UNNotificationAction(identifier: recordAction, title: "Start recording", options: [.foreground])
        // Not in the foreground: keeping a recording going shouldn't take you away from the call.
        let keep = UNNotificationAction(identifier: keepAction, title: "Keep recording", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [start], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: callCategory, actions: [record], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: stopCategory, actions: [keep], intentIdentifiers: [])])
    }

    /// Something about the recording you'd want to know while looking at the call, not at Oatcake.
    /// One with the same `id` replaces the one before it.
    static func say(_ title: String, _ body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        post(content, id: id)
    }

    /// The call seems to be over: recording stops in half a minute unless Keep recording is chosen.
    static func warnOfStop() {
        let content = UNMutableNotificationContent()
        content.title = "The call seems to have ended"
        content.body = "Recording stops in 30 seconds."
        content.categoryIdentifier = stopCategory
        content.sound = .default
        post(content, id: stopCategory)
    }

    static func withdrawStopWarning() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [stopCategory])
        center.removePendingNotificationRequests(withIdentifiers: [stopCategory])
    }

    private static func post(_ content: UNMutableNotificationContent, id: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// A calling app has started using the microphone and nothing is being recorded.
    static func offerRecording(app: String, event: CalendarEvent?) {
        let content = UNMutableNotificationContent()
        content.title = "On a call?"
        content.body = "\(app) is using your microphone\(event.map { " (\($0.title))" } ?? ""). Oatcake isn’t recording."
        content.categoryIdentifier = callCategory
        content.sound = .default
        post(content, id: "call-noticed")
    }

    /// A recording stopped by itself because its call ended.
    static func stopped(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The call ended, so Oatcake stopped recording “\(title)” and is transcribing it."
        post(content, id: "call-ended")
    }

    static func show(_ event: CalendarEvent) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let minutes = Int((event.startDate.timeIntervalSinceNow / 60).rounded())
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = [minutes > 0 ? "In \(minutes) min" : "Starting now", "\(hhmm(event.startDate))–\(hhmm(event.endDate))",
                            event.callLink.flatMap(callApp)].compactMap { $0 }.joined(separator: " · ")
            content.categoryIdentifier = category
            content.userInfo = ["event": (try? encodeJSON(event)) ?? ""]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }

    static func event(from response: UNNotificationResponse) -> CalendarEvent? {
        (response.notification.request.content.userInfo["event"] as? String)
            .flatMap { try? JSONDecoder().decode(CalendarEvent.self, from: Data($0.utf8)) }
    }
}

// MARK: - Ask

struct AskTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String?
    var error: String?
    var stopped = false
    var step: String?
    var startedAt = Date()
    var running: Bool { answer == nil && error == nil && !stopped }
}

/// One conversation for as long as the app is open. It carries on as you move between meetings, so
/// following a link in an answer doesn't lose it. Each question is asked about the meeting that's open.
@MainActor @Observable
final class AskChat {
    var turns: [AskTurn] = []
    var open = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var running: AskTurn? { turns.first(where: \.running) }

    func send(_ question: String, meeting: String, app: AppModel) {
        let history = turns.compactMap { turn in turn.answer.map { AskExchange(question: turn.question, answer: $0) } }
        let turn = AskTurn(question: question)
        turns.append(turn)
        open = true
        let config = app.config
        tasks[turn.id] = Task {
            do {
                // The first question may find the model still on its way.
                let waiting = Task {
                    while !Task.isCancelled {
                        if let status = app.modelDownloadStatus { update(turn.id) { $0.step = status } }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                defer { waiting.cancel() }
                try await app.ensureModel()
                waiting.cancel()
                let answer = try await OatcakeCore.ask(config, meeting: meeting, question: question, history: history) { step in
                    Task { @MainActor in self.update(turn.id) { $0.step = step } }
                }
                update(turn.id) { $0.answer = answer }
            } catch {
                let message = error.localizedDescription
                update(turn.id) { if Task.isCancelled || isCancellation(error) { $0.stopped = true } else { $0.error = message } }
            }
            tasks.removeValue(forKey: turn.id)
        }
    }

    func cancel() {
        if let running { tasks[running.id]?.cancel() }
    }

    func newChat() {
        turns = []
        open = true
    }

    private func update(_ id: UUID, _ change: (inout AskTurn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { change(&turns[i]) }
    }
}

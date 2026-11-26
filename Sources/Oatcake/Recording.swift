// The call being recorded: starting and stopping the recorder, watching that it's still there and
// still hearing something, noticing when the call starts and ends, the live transcript, the notes
// typed during the call, and what the menu bar shows.

import AppKit
import OatcakeCore
import SwiftUI

/// A line typed during a call.
struct LiveLine: Identifiable, Equatable {
    let id = UUID()
    /// Seconds in when typing started; nil until then, and always for prep notes.
    var at: Double?
    var prep: Bool
    var text: String
}

/// What the live transcript's helper is doing.
enum LiveTranscriptState: Equatable {
    /// No helper: the live transcript is off, or there's no call.
    case idle
    /// The helper is on its way up and hasn't said anything yet.
    case starting
    case at(LiveStage)
    /// It stopped, and why.
    case stopped(String)
}

@MainActor @Observable
final class RecordingController {
    /// What this part asks of the app around it.
    var app = AppServices()
    /// The question being asked about the call being recorded ("Stop recording?"), if one is.
    private var liveQuestion: Confirmation.ID?
    /// The calendar: the event a call belongs to, its call link, and the next call for the menu bar.
    private let calendar: CalendarController
    /// The language model, fetched while the first call is recorded.
    private let downloads: ModelDownloads
    /// The folder in the Meetings folder that an event's recording goes in (its title, and whether it recurs).
    var folderForEvent: @MainActor (_ title: String, _ recurring: Bool) throws -> String = { _, _ in "" }
    /// The call is over and its recording is on its way to being processed.
    var ended: @MainActor (Recording) -> Void = { _ in }
    private var config: Config { app.config() }
    private func toast(_ text: String, isError: Bool = false) { app.toast(text, isError) }
    private func refresh() { app.refresh() }
    private func showWindow() { app.showWindow() }
    private var selection: Selection? {
        get { app.selection() }
        set { app.select(newValue) }
    }

    var live: Recording?
    /// The call being recorded, as it's heard: lines from the live helper, and what the helper is doing.
    var liveLines: [LiveTranscriptLine] = []
    var liveState = LiveTranscriptState.idle
    /// The lines you've said who said during this call, as kept in the recording (live-names.json).
    var liveNames: [LiveName] = []
    var status = RecorderStatus(state: .starting)
    /// Why the call that's "live" isn't being recorded at all: the recorder never started. The live
    /// screen stays, saying so, until it's closed.
    var recorderFailure: String?
    /// The recorder said so itself (it couldn't use the microphone, say). Otherwise the failure is
    /// only that nothing has been heard from it, which a recorder that's slow to start can still put right.
    private var failureIsFinal = false
    /// Since when the microphone, and the call audio, have had nothing in them; nil while there's sound.
    var micQuietSince: Date?
    var callQuietSince: Date?
    /// When the recording will stop by itself because the call seems to have ended, once it has said so.
    var stoppingAt: Date?
    /// Why the notes typed during the call couldn't be saved, until a save works.
    var liveNotesError: String?
    /// Notes typed during each call, kept here so leaving the live view and coming back keeps them.
    var liveNotes: [String: [LiveLine]] = [:]

    /// Recorders running now, by recording ID.
    private var active: [String: Recording] = [:]
    /// Calendar events recorded since launch, kept after their recordings are saved and tidied away.
    private var recordedEvents = Set<String>()
    private var liveHelper: ChildProcess.Handle?
    /// The recording whose live transcript helper is running or on its way up. A second helper for the
    /// same recording would say every line again.
    private var liveTranscriptFor: String?
    /// The helper running now, and whether it names voices: one told to stop may still say a line or two.
    private var liveRun: UUID?
    private var liveRunNamesVoices = false
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
    private var micSilence = MicSilence()
    private var callQuietSaid = false
    let menuBar = MenuBarItem()
    private var timers: [Timer] = []
    private var statusTimer: Timer?
    private var notesSaveTask: Task<Void, Never>?

    init(calendar: CalendarController, downloads: ModelDownloads) {
        self.calendar = calendar
        self.downloads = downloads
    }

    /// From launch on, every couple of seconds: is the recorder still there, and is there a call?
    func startChecks() {
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                self.checkRecorder()
                self.checkCall()
            }
        })
    }

    /// The settings have changed: a recording in progress follows them straight away.
    func settingsChanged(_ saved: Config) {
        for rec in active.values { try? Recordings.setMic(rec.dir, uid: saved.mic?.uid) }
        // The live transcript follows its switch straight away, mid-call too.
        // (Not for a call that couldn't be recorded: there's nothing for it to transcribe.)
        if let live, recorderFailure == nil {
            if !saved.liveTranscript {
                stopLiveTranscript()
            } else if liveHelper == nil {
                startLiveTranscript(live)
            } else if saved.liveVoices != liveRunNamesVoices {
                // Naming voices takes a helper that has loaded the voice models, or frees their memory:
                // it starts again, and goes through the call so far.
                stopLiveTranscript()
                startLiveTranscript(live)
            }
        }
        updateMenuBar()
    }

    /// Opens the call's link, starts recording it, and brings Oatcake forward on the live notes.
    func startFromEvent(_ event: CalendarEvent) {
        if let link = event.callLink, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        // Already recording: go back to that recording rather than start a second.
        if active.isEmpty {
            do {
                let folder = try folderForEvent(event.title, event.seriesId != nil)
                try startRecording(title: event.title, folder: folder, options: startOptions(event))
            } catch {
                // Said in Oatcake's window and as a notification: the call's own window is in front by now,
                // and an alert would sit behind it while the call went unrecorded.
                showWindow()
                toast(error.localizedDescription, isError: true)
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

    // MARK: - Recording

    /// A recording started straight from a calendar event carries the event, any prep notes written
    /// for it on New recording, and who else is invited.
    private func startOptions(_ event: CalendarEvent) -> Recordings.StartOptions {
        .init(eventId: event.id, prep: PrepNotes.load(event.id), attendees: otherAttendees(event, myName: config.myName).map(attendeeName))
    }

    /// The link to the call being recorded, when it was started from a calendar event that has one.
    var liveCallLink: URL? {
        guard let id = live?.eventId, let link = calendar.cache?.events.first(where: { $0.id == id })?.callLink else { return nil }
        return URL(string: link)
    }

    func startRecording(title: String, folder: String, options: Recordings.StartOptions) throws {
        // One call at a time: a second recorder would capture the same audio.
        guard active.isEmpty else { throw OatcakeError("Oatcake is already recording a call. Stop it first.") }
        let rec = try Recordings.start(title: title, folder: folder, micUid: config.mic?.uid, options: options)
        active[rec.id] = rec
        if let eventId = options.eventId { recordedEvents.insert(eventId) }
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
        if let chosenModel = downloads.chosenModel, !LocalModels.isDownloaded(chosenModel) { downloads.downloadModel(chosenModel) }
    }

    /// Recordings left from an earlier run: a recorder still going is picked up again; a dead one is finished off.
    func resumeRecordings() {
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
        let finished = { FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent(RecorderFile.meta).path) }
        // A recorder that's only just coming up has no process to stop yet. Left alone it would start
        // afterwards and record with nobody watching, so from now on it's told no when it asks (it
        // asks before it records). One that has already asked is given a moment to appear, so that
        // it can be stopped like any other. A recorder that has been and gone isn't waited for.
        if !finished(), !Recordings.isRunning(rec) {
            Recordings.cancelStart(rec)
            if Recordings.status(rec).state == .starting {
                for _ in 0..<30 where !finished() && !Recordings.isRunning(rec) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        Recordings.stop(rec)
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
        if let liveQuestion { app.withdraw(liveQuestion) }
        liveQuestion = nil
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
        failureIsFinal = false
        liveNotesError = nil
        micQuietSince = nil
        callQuietSince = nil
        micSilence = MicSilence()
        callQuietSaid = false
        keepsRecording = false
        withdrawStopWarning()
    }

    /// The call is over: on to processing it. If you were on its notes you go to its progress;
    /// anywhere else, you stay there.
    private func liveEnded(_ rec: Recording, watching: Bool) {
        endLive()
        ended(rec)
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
        guard let rec = live, !endingLive else { return }
        if recorderFailure != nil {
            // "It didn't start" was only that nothing had been heard from it. A recorder that turns up
            // late is recording after all: the call goes back to being a recording like any other.
            // One that then says why it failed has had the last word.
            guard !failureIsFinal else { return }
            let status = Recordings.status(rec)
            if Recordings.isRunning(rec) {
                recorderFailure = nil
                startLiveTranscript(rec)
                updateMenuBar()
                // In place of the notification that said it couldn't.
                Reminders.say("Oatcake is recording after all", "The recorder was slow to start. “\(rec.title)” is being recorded.", id: "recorder-failed")
            } else if status.state == .error {
                recorderFailure = status.error ?? "The recorder stopped."
                failureIsFinal = true
            }
            return
        }
        guard !Recordings.isRunning(rec) else { return }
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
        failureIsFinal = status.state != .starting
        stopLiveTranscript()
        updateMenuBar()
        Reminders.say("Oatcake couldn’t start recording", why, id: "recorder-failed")
    }

    /// Silence: after half a minute of it the live screen says so, for as long as it lasts, and
    /// there's a notification: for the call audio once for each quiet spell, for the microphone
    /// once a recording and once more after a change of microphone (MicSilence says why).
    private func trackSilence() {
        guard status.state == .recording, recorderFailure == nil else { return }
        let now = Date()
        let sayMic = micSilence.look(device: status.micDevice?.uid, quiet: (status.micLevel ?? 0) < 0.001, at: now)
        let callQuiet = callAudioQuiet
        let call = callQuiet ? (callQuietSince ?? now) : nil
        if micSilence.since != micQuietSince { micQuietSince = micSilence.since }
        if call != callQuietSince { callQuietSince = call }
        if !callQuiet { callQuietSaid = false }
        if sayMic {
            Reminders.say("Your microphone has been silent for 30 seconds", "Check it isn’t muted, or pick another microphone in Oatcake.", id: "mic-quiet")
        }
        // Only while a calling app has the microphone: dictating notes on your own, there is no call audio to miss.
        if let call, now.timeIntervalSince(call) >= 30, !callQuietSaid, callOnMic {
            callQuietSaid = true
            Reminders.say("No call audio for 30 seconds",
                          "If people are talking, allow Oatcake in System Settings › Privacy & Security › Screen & System Audio Recording.", id: "call-quiet")
        }
    }

    /// No call audio right now. Oatcake's own notification sounds come out of the Mac like any other
    /// sound and are recorded as call audio, so for a few seconds after one, what's heard isn't taken
    /// for the call: otherwise the warning that recording is about to stop would call itself off,
    /// and the notice that the call is silent would end the silence it reports.
    private var callAudioQuiet: Bool {
        (status.systemLevel ?? 0) < 0.001 || Date().timeIntervalSince(Reminders.lastSound) < 6
    }

    func confirmStop() {
        ask(Confirmation(
            title: "Stop recording?",
            text: "Oatcake will transcribe the call and ask you to check who’s who. You can’t add more to this recording afterwards.",
            ok: "Stop recording", cancel: "Keep recording") { [self] in await stopLive() })
    }

    /// A question about the call being recorded. If the recording ends some other way while it's
    /// still up (the recorder stops by itself, the call ends), the question goes with it.
    private func ask(_ question: Confirmation) {
        liveQuestion = question.id
        app.confirm(question)
    }

    /// Stops the call being recorded and starts processing it. If you're on its notes you go to its
    /// progress; anywhere else, you stay there. False when there was nothing for it to stop: no call,
    /// or one that something else is already ending.
    @discardableResult
    func stopLive() async -> Bool {
        guard let rec = live, !endingLive else { return false }
        endingLive = true
        defer { endingLive = false }
        let watching = selection == .live
        saveLiveNotes(rec.id)
        await stopRecorder(rec)
        liveEnded(rec, watching: watching)
        return true
    }

    /// Cancel before any audio arrived (or Close, when the recorder never started): stop the recorder
    /// and throw the recording away.
    func cancelRecording(hasNotes: Bool) {
        let cancel = { [self] in
            guard let rec = live, !endingLive else { return }
            endingLive = true
            defer { endingLive = false }
            await stopRecorder(rec)
            // The call is over here whether or not its folder could be deleted: left "live" with its
            // recorder gone, it would be announced a moment later as a recording that had stopped.
            let discarded = Result { try Recordings.discard(rec.id) }
            liveNotes.removeValue(forKey: rec.id)
            endLive()
            app.showFolder()
            refresh()
            try discarded.get()
            toast("Recording cancelled")
        }
        if !hasNotes {
            Task { do { try await cancel() } catch { toast(error.localizedDescription, isError: true) } }
            return
        }
        ask(Confirmation(title: "Cancel this recording?",
                                    text: "Nothing has been recorded yet. The notes you’ve typed for it will be deleted.",
                                    ok: "Cancel recording", cancel: "Keep waiting", action: cancel))
    }

    /// Never leave the recorder (or the language model) running behind a closed app.
    func stopAllRecorders() {
        if let live { saveLiveNotes(live.id) }
        stopLiveTranscript()
        for rec in active.values {
            // One that hasn't got going yet is told no when it asks, rather than left to start after Oatcake has gone.
            if !Recordings.isRunning(rec) { Recordings.cancelStart(rec) }
            Recordings.stop(rec)
            // A call that couldn't be recorded is thrown away, as Close would: left behind, its empty
            // folder would come back at the next launch as a recording to process.
            if rec.id == live?.id, recorderFailure != nil { try? Recordings.discard(rec.id) }
        }
        ModelServer.stopLeftover()
    }

    /// A call that couldn't be recorded isn't one that's being recorded: it holds up nothing.
    var isRecording: Bool { !active.isEmpty && recorderFailure == nil }

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
                  status.state == .recording, callAudioQuiet else {
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
            // Stop recording part-way through a call and there's no offer to record it again.
            callOffered = true
        } else if config.callNotice, !callOffered, now.timeIntervalSince(callSince!) >= 4 {
            callOffered = true
            Reminders.offerRecording(app: apps[0], event: noticedCallEvent)
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
            // Not if something else got there first (your own Stop, or the recorder going by itself).
            guard await stopLive() else { return }
            Reminders.stopped(rec.title)
            toast("The call ended, so recording stopped")
        }
    }

    /// The calendar event a call Oatcake noticed by itself belongs to: the one happening now, unless it
    /// has been recorded already. Its call may have finished early and this be another one in its slot.
    /// A recording started from the event itself (New recording, Upcoming) isn't asked this.
    var noticedCallEvent: CalendarEvent? {
        let recorded = recordedEvents.union(Recordings.list().compactMap(\.eventId))
        return calendar.currentEvent(unless: recorded)
    }

    /// From the "On a call?" notification: record it, under the calendar event happening now if there is one.
    func recordCall() {
        showWindow()
        guard active.isEmpty else { return selection = .live }
        do {
            if let event = noticedCallEvent {
                let folder = try folderForEvent(event.title, event.seriesId != nil)
                try startRecording(title: event.title, folder: folder, options: startOptions(event))
            } else {
                try startRecording(title: "Call", folder: "", options: .init())
            }
        } catch {
            toast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Live transcript

    private func startLiveTranscript(_ rec: Recording) {
        // Asked for again while the helper is still on its way up (settings saved just after the call
        // started, say): one is enough.
        guard liveTranscriptFor != rec.id else { return }
        liveLines = []
        liveState = .idle
        liveNames = LiveNames.load(rec.dir)
        guard config.liveTranscript, liveHelper == nil else { return }
        liveTranscriptFor = rec.id
        liveState = .starting
        let run = UUID()
        liveRun = run
        liveRunNamesVoices = config.liveVoices
        Task {
            _ = try? await ChildProcess.run(Bundle.main.executableURL!, [HelperMode.live, rec.dir.path], onStart: { process in
                Task { @MainActor in
                    // The call may have ended (or the switch been turned off) before the helper got going.
                    if self.live?.id == rec.id, self.liveTranscriptFor == rec.id, self.config.liveTranscript { self.liveHelper = process } else { process.terminate() }
                }
            }, onLine: { line in
                guard let event = try? JSONDecoder().decode(LiveEvent.self, from: Data(line.utf8)) else { return }
                Task { @MainActor in
                    guard self.live?.id == rec.id, self.liveRun == run else { return }
                    if let line = event.line { self.liveLines.append(line) }
                    for change in event.names ?? [] {
                        if let i = self.liveLines.firstIndex(where: { $0.id == change.line }) { self.liveLines[i].speaker = change.name }
                    }
                    if let stage = event.stage { self.liveState = .at(stage) }
                    if let error = event.error { self.liveState = .stopped(error) }
                }
            })
        }
    }

    private func stopLiveTranscript() {
        liveHelper?.terminate()
        liveHelper = nil
        liveTranscriptFor = nil
        liveRun = nil
    }

    /// You've said who said a line of the live transcript (nil: you take it back). It's kept in the
    /// recording, where the helper follows it for the rest of the call and Who's who finds it after.
    func nameLiveLine(_ line: LiveTranscriptLine, as name: String?) {
        guard let live else { return }
        // Whatever was given for this line, also under the line it was before the transcript started again.
        var names = liveNames.filter { liveName(for: line, in: [$0]) == nil }
        if let name { names.append(LiveName(line: line, name: name)) }
        do {
            try LiveNames.save(names, in: live.dir)
            liveNames = names
            // Shown straight away; the helper names the lines that sound like it a moment later. A name
            // taken back stays until the helper has decided again.
            if let name, let i = liveLines.firstIndex(where: { $0.id == line.id }) { liveLines[i].speaker = name }
        } catch {
            toast("Couldn’t keep that name: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Menu bar

    /// The menu bar shows the call being recorded (with Stop); otherwise, with a calendar connected and
    /// the setting on, the time until the next call; otherwise, with Run in the background on, just
    /// Oatcake's icon, so that Oatcake can be reopened with its window closed.
    func updateMenuBar() {
        // A call that couldn't be recorded isn't shown as one that is.
        if let live, recorderFailure == nil {
            menuBar.show(.recording(title: live.title, elapsed: status.state == .recording ? status.elapsed ?? 0 : nil))
        } else if config.menuBarNextCall && calendar.cache != nil {
            let now = Date()
            menuBar.show(.upcoming(calendar.events.filter { !$0.allDay && $0.endDate > now }))
        } else if config.runInBackground {
            menuBar.show(.idle)
        } else {
            menuBar.hide()
        }
    }
}

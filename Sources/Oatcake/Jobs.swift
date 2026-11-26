// Recordings after the call: analysing them, checking who's who, saving them as meetings and
// writing their summaries.

import AppKit
import OatcakeCore
import SwiftUI

struct JobProgress: Equatable {
    /// Where the analysis has got to; nil before it has said ("Starting").
    var stage: AnalysisStage?
    var fraction: Double?
    var error: String?
    /// What kind of failure `error` is.
    var failure: AnalysisFailure?
    /// Waiting for another recording's analysis to finish: they're done one at a time.
    var waiting = false
}

/// What you've set on a Who's who screen, kept by the app so looking at something else and coming
/// back loses nothing.
struct ReviewDraft: Equatable {
    struct Voice: Equatable {
        var name: String
        /// The name was picked from the calendar invite.
        var fromInvite = false
        var mixed = false
        /// Not part of the call (people talking in the background, say): its lines aren't saved.
        var leftOut = false
        /// Merged into another voice (`me` for your microphone).
        var into: String?
    }
    var title: String
    /// Where the meeting will be saved, relative to the Meetings folder.
    var folder: String
    var voices: [String: Voice]
}

@MainActor @Observable
final class Jobs {
    /// What this part asks of the app around it.
    var app = AppServices()
    /// The language model: summaries wait for it, and name suggestions start it downloading.
    private let downloads: ModelDownloads
    private var config: Config { app.config() }
    private func toast(_ text: String, isError: Bool = false) { app.toast(text, isError) }
    private func refresh() { app.refresh() }

    var pending: [Recording] = []
    /// Recordings saved as meetings without checking who's who, whose voices can still be named.
    var unchecked: [Recording] = []
    var progress: [String: JobProgress] = [:]
    /// Meetings whose summary is being written now, and why the last attempt failed, by path.
    var summarising = Set<String>()
    var summaryErrors: [String: String] = [:]
    /// What Regenerate is writing again, by path; kept after a failure, so Try again knows what to retry.
    var regenerating: [String: SummaryPart] = [:]
    /// The template a summary is being regenerated with, by path; kept after a failure, for Try again.
    var regeneratingWith: [String: SummaryTemplateChoice] = [:]
    /// Where each meeting being summarised lives now: it can be renamed or moved while the model writes.
    private var summaryJobs: [UUID: String] = [:]
    /// Summaries being written of a transcript that has since had its voices named (a meeting saved
    /// without checking who's who): what the model is writing has the old names, so it's asked again.
    private var staleSummaries = Set<UUID>()
    /// Jobs regenerating a meeting's to-dos that are followed by its summary: a voice was left out meanwhile.
    private var summaryAgain = Set<UUID>()
    var reviewDrafts: [String: ReviewDraft] = [:]
    /// Meetings whose to-dos couldn't be read from the model's reply, and why, by path.
    var todoProblems: [String: String] = [:]
    /// Meetings whose draft for sharing is being written now, and why the last attempt failed, by path.
    var drafting = Set<String>()
    var draftErrors: [String: String] = [:]
    /// What was asked for a draft alone, by path: kept after a failure, so Try again asks the same.
    var draftRequests: [String: String] = [:]
    /// Where each meeting whose draft is being written lives now: it can be renamed or moved meanwhile.
    private var draftJobs: [UUID: String] = [:]
    private var analysing = Set<String>()
    /// The analysis helper running for each recording, and the work around it (which goes on to
    /// suggest names), so discarding a recording stops both.
    private var helpers: [String: ChildProcess.Handle] = [:]
    private var analyses: [String: Task<Void, Never>] = [:]
    private var autoStarted = Set<String>()
    /// One analysis helper at a time: each loads the speech models and its whole call, so several at
    /// once (recordings left from before a quit, back-to-back calls) would hold several of each.
    private var helperBusy = false
    private var helperQueue: [CheckedContinuation<Void, Never>] = []
    /// One at a time: two clear-ups at once could both be writing the same meeting's audio.
    private let tidying = DispatchQueue(label: "oatcake.tidy-saved", qos: .utility)

    init(downloads: ModelDownloads) {
        self.downloads = downloads
    }

    /// Whether any call is being analysed now.
    var isAnalysingAny: Bool { !analysing.isEmpty }

    /// Recordings waiting to be processed start straight away, in the background, one at a time. So
    /// does the last step of one that a quit cut short (names, then saving by itself).
    func startWaiting() {
        for rec in pending where !autoStarted.contains(rec.id) && !analysing.contains(rec.id) {
            if rec.state == .recorded {
                autoStarted.insert(rec.id)
                analyse(rec.id)
            } else if rec.state == .processed, Recordings.lastStepPending(rec) {
                autoStarted.insert(rec.id)
                analysing.insert(rec.id)
                analyses[rec.id] = Task { await finish(rec, AnalysisProgress(done: true)) }
            }
        }
    }

    /// A folder or meeting has been renamed or moved: `remap` gives a path's new place.
    func moved(_ remap: (String) -> String) {
        // A summary on its way follows the meeting to where it is now.
        summarising = Set(summarising.map(remap))
        summaryJobs = summaryJobs.mapValues(remap)
        summaryErrors = Dictionary(summaryErrors.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        regenerating = Dictionary(regenerating.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        regeneratingWith = Dictionary(regeneratingWith.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        todoProblems = Dictionary(todoProblems.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        drafting = Set(drafting.map(remap))
        draftJobs = draftJobs.mapValues(remap)
        draftErrors = Dictionary(draftErrors.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        draftRequests = Dictionary(draftRequests.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        // A recording waiting in Who's who is still saved into the folder it was set to, wherever that is now.
        reviewDrafts = reviewDrafts.mapValues { draft in with(draft) { $0.folder = remap($0.folder) } }
    }

    func analyse(_ id: String) {
        guard let rec = Recordings.get(id), !analysing.contains(id) else { return }
        analysing.insert(id)
        progress[id] = JobProgress(stage: progress[id]?.stage, waiting: helperBusy)
        analyses[id] = Task {
            let outcome = await runHelper(rec)
            await finish(rec, outcome)
        }
    }

    /// Waits for the helper before this one to finish.
    private func helperTurn() async {
        guard helperBusy else {
            helperBusy = true
            return
        }
        await withCheckedContinuation { helperQueue.append($0) }
    }

    private func helperDone() {
        if helperQueue.isEmpty { helperBusy = false } else { helperQueue.removeFirst().resume() }
    }

    /// Runs the analysis helper, when its turn comes, and says how it went.
    private func runHelper(_ rec: Recording) async -> AnalysisProgress? {
        let id = rec.id
        await helperTurn()
        defer { helperDone() }
        // Discarded while it waited.
        guard Recordings.get(id) != nil, !Task.isCancelled else { return nil }
        progress[id]?.waiting = false
        // A recorder that went without meta.json when one couldn't be written: there may be room now.
        Recordings.finishInterrupted(rec)
        // Steps arrive as they happen; the outcome is read from the full output once it exits.
        let result = try? await ChildProcess.run(Bundle.main.executableURL!, [HelperMode.analyse, rec.dir.path], onStart: { process in
            Task { @MainActor in self.helpers[id] = process }
        }, onLine: { line in
            guard let p = try? JSONDecoder().decode(AnalysisProgress.self, from: Data(line.utf8)), p.stage != nil else { return }
            Task { @MainActor in self.apply(id, p) }
        })
        helpers.removeValue(forKey: id)
        let outcome = (result?.stdout ?? "").split(separator: "\n").reversed()
            .compactMap { try? JSONDecoder().decode(AnalysisProgress.self, from: Data($0.utf8)) }
            .first { $0.done == true || $0.error != nil }
        if let outcome { return outcome }
        if result?.status == 0, FileManager.default.fileExists(atPath: rec.dir.appendingPathComponent("analysis.json").path) {
            return AnalysisProgress(done: true)
        }
        let detail = result.map { $0.stderr.trimmed.isEmpty ? "" : ": " + String($0.stderr.trimmed.suffix(300)) } ?? ""
        return AnalysisProgress(error: "Analysis stopped (code \(result?.status ?? -1))\(detail)", failure: .helperStopped)
    }

    /// What's left once the helper is done: step 5, then saving the call by itself if Settings says
    /// so, then saying how it went.
    private func finish(_ rec: Recording, _ outcome: AnalysisProgress?) async {
        let id = rec.id
        // Step 5, here rather than in the helper: the language model is the app's to run. A model
        // that's still downloading isn't waited for; the names can be typed. Saving the transcript only
        // asks nothing of the model: the call is saved without its guesses anyway (suggestedDecisions),
        // and waiting for them held the save up. Naming its voices later starts without them.
        if outcome?.done == true, Recordings.get(id) != nil, !Task.isCancelled, hasUnnamedVoices(rec.dir) {
            if let chosenModel = downloads.chosenModel, !LocalModels.isDownloaded(chosenModel) { downloads.downloadModel(chosenModel) }
            if config.afterCall != .saveTranscript {
                progress[id] = JobProgress(stage: .suggestingNames)
                await suggestNames(rec.dir, config: config)
            }
        }
        // Settings › General › After a call: saved now, rather than waiting under Needs review. Still
        // counted as being analysed meanwhile, so Who's who can't open and save it a second time.
        if outcome?.done == true, Recordings.get(id) != nil, !Task.isCancelled, config.afterCall != .review { await autoSave(id) }
        if outcome?.done == true { Recordings.lastStepDone(rec) }
        analysing.remove(id)
        analyses.removeValue(forKey: id)
        // Discarded while it ran: nothing to report.
        guard Recordings.get(id) != nil else {
            progress.removeValue(forKey: id)
            return
        }
        if let outcome { apply(id, outcome) }
    }

    /// Saves a processed recording as a meeting without stopping at who's who: a voice Oatcake
    /// recognised under that person's name, the rest as "Voice 1"… They can be named later from the
    /// meeting. If it can't be saved, it waits under Needs review as usual.
    private func autoSave(_ id: String) async {
        guard let rec = Recordings.get(id), rec.state == .processed, let analysis = try? loadAnalysis(rec) else { return }
        // Nothing heard in a call that has audio (a very quiet microphone, a track that couldn't be
        // transcribed): saved, it would have an empty transcript, and with Keep call audio off its
        // tracks would go and it couldn't be analysed again.
        if analysis.lines.isEmpty, Recordings.audioSeconds(rec) > 5 {
            toast("Couldn’t save “\(rec.title)” by itself: no speech was found in its audio. It’s waiting under Needs review.", isError: true)
            return
        }
        let folder = rec.folder ?? ""
        let withSummary = config.afterCall == .saveWithSummary
        let config = config
        do {
            // Off the main thread: with Keep call audio off it deletes the call's tracks, and it writes
            // the transcript and voiceprints.
            let path = try await Task.detached {
                try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: folder, title: rec.title, unchecked: true)
            }.value
            reviewDrafts.removeValue(forKey: id)
            if withSummary { writeSummary(path) }
            tidySavedRecordings()
            toast("“\(rec.title)” saved to \(folderPath(folder))")
            refresh()
            // Watching it being processed: on to the meeting.
            if app.selection() == .job(id) { app.select(.meeting(path, jump: Jump(tab: withSummary ? .summary : .transcript))) }
        } catch {
            toast("Couldn’t save “\(rec.title)” by itself: \(error.localizedDescription) It’s waiting under Needs review.", isError: true)
        }
    }

    /// Names the voices of a meeting saved without checking: its transcript and meeting.json are
    /// written again in place, and the new names are put into its summary and to-dos. Returns its path.
    func updateMeeting(_ rec: Recording, decisions: [String: Decision]) throws -> String {
        guard let path = Recordings.meetingPath(rec, meetingsRoot: config.meetingsRoot) else {
            throw OatcakeError("The meeting saved from this recording couldn’t be found. It may have been deleted.")
        }
        // Asked before saving: after it, what the voices were saved as is no longer on record.
        let leftOut = leavesOutSavedVoice(rec, decisions)
        let saved = try saveMeeting(config, rec, decisions: decisions, folder: "", into: path)
        // A summary of it that's still being written was asked for with the old names.
        let writing = summaryJobs.filter { $0.value == saved }.map(\.key)
        staleSummaries.formUnion(writing)
        // A voice left out of a meeting that has its summary already: putting new names in can't take
        // out what the summary says of that voice, so the summary is written again from the transcript
        // as it is now. One being written is read again anyway; a job that's only regenerating the
        // to-dos is followed by the summary.
        if leftOut, (try? Meetings(root: config.meetingsRoot).read(saved).summary.trimmed.isEmpty) == false {
            if writing.isEmpty {
                writeSummary(saved, only: .summary)
            } else if regenerating[saved] == .todos {
                summaryAgain.formUnion(writing)
            }
        }
        reviewDrafts.removeValue(forKey: rec.id)
        tidySavedRecordings()
        return saved
    }

    /// Keep as is: the meeting stays with the names it was saved with, and the recording's working
    /// folder (its analysis, voice fingerprints and clips) is cleared away.
    func keepAsIs(_ id: String) {
        guard let rec = unchecked.first(where: { $0.id == id }) else { return }
        do {
            try Recordings.markChecked(rec)
            reviewDrafts.removeValue(forKey: id)
            tidySavedRecordings()
            refresh()
        } catch {
            toast(error.localizedDescription, isError: true)
        }
    }

    /// Whether a recording is still being worked on (its review waits until it isn't).
    func isAnalysing(_ id: String) -> Bool { analysing.contains(id) }

    private func apply(_ id: String, _ p: AnalysisProgress) {
        if p.done == true {
            progress.removeValue(forKey: id)
            refresh()
        } else if let error = p.error {
            progress[id] = JobProgress(stage: progress[id]?.stage, error: error, failure: p.failure ?? .other)
        } else if let stage = p.stage {
            progress[id] = JobProgress(stage: stage, fraction: p.fraction)
        }
        updateBadge()
    }

    func retry(_ rec: Recording) {
        progress[rec.id] = JobProgress()
        analyse(rec.id)
    }

    func discard(_ rec: Recording) {
        app.confirm(Confirmation(title: "Discard this recording?",
                                    text: "The audio, transcript and your notes will be deleted. This can’t be undone.",
                                    ok: "Discard", cancel: "Cancel") { [self] in
            // A helper still analysing it would write its transcript and clips back after the folder had gone.
            helpers.removeValue(forKey: rec.id)?.terminate()
            analyses.removeValue(forKey: rec.id)?.cancel()
            // One still waiting its turn finds it gone when the turn comes; it isn't work under way meanwhile.
            analysing.remove(rec.id)
            try Recordings.discard(rec.id)
            reviewDrafts.removeValue(forKey: rec.id)
            progress.removeValue(forKey: rec.id)
            app.showFolder()
            toast("Recording discarded")
            refresh()
        })
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
    func tidySavedRecordings() {
        let root = config.meetingsRoot
        tidying.async {
            let problems = Recordings.tidySaved(meetingsRoot: root)
            // Said, rather than left to happen again unseen: the folder is kept and tried again next time.
            if let first = problems.first { Task { @MainActor in self.toast(first, isError: true) } }
        }
    }

    /// Regenerate summary or Regenerate to-dos: asks first, as it replaces what's there. The old one
    /// stays until the new one is written. A summary can be written with a template picked for it,
    /// which the meeting then keeps.
    func regenerate(_ part: SummaryPart, _ path: String, template: SummaryTemplateChoice = .meetings) {
        guard !summarising.contains(path) else { return }
        let summaryText: String
        switch template {
        case .picked(let name?) where config.summaryTemplate(named: name) != nil:
            summaryText = "It’s written again with the “\(name)” template and replaces this summary, including any edits. The meeting keeps the template for summaries written of it later. Your transcript, notes and to-dos are kept."
        case .picked:
            summaryText = "It’s written again with your summary instructions in Settings and replaces this summary, including any edits. Your transcript, notes and to-dos are kept."
        case .meetings:
            summaryText = "It’s written again with your current instructions in Settings and replaces this summary, including any edits. Your transcript, notes and to-dos are kept."
        }
        let confirmation = part == .summary
            ? Confirmation(title: "Regenerate this summary?", text: summaryText,
                           ok: "Regenerate summary", cancel: "Cancel") { [self] in writeSummary(path, only: .summary, template: template) }
            : Confirmation(title: "Regenerate these to-dos?",
                           text: "They’re written again with your current instructions in Settings and replace these to-dos, including any you’ve ticked, added or edited. Your transcript, notes and summary are kept.",
                           ok: "Regenerate to-dos", cancel: "Cancel") { [self] in writeSummary(path, only: .todos) }
        app.confirm(confirmation)
    }

    /// Writes a saved meeting's summary and to-dos in the background: after every save, and from
    /// Write summary when an earlier attempt couldn't reach the model. With `only`, that one part is
    /// written again in place of what's there (Regenerate), with `template` for a summary.
    func writeSummary(_ path: String, only part: SummaryPart? = nil, template: SummaryTemplateChoice = .meetings) {
        guard !summarising.contains(path) else { return }
        summarising.insert(path)
        summaryErrors.removeValue(forKey: path)
        if part != .summary { todoProblems.removeValue(forKey: path) }
        regenerating[path] = part
        if part == .summary { regeneratingWith[path] = template } else { regeneratingWith.removeValue(forKey: path) }
        let job = UUID()
        summaryJobs[job] = path
        let config = config
        Task {
            defer { staleSummaries.remove(job) }
            do {
                // What's there now: if it's changed by the time the model is done, it isn't replaced.
                @MainActor func partNow() throws -> String? {
                    try part.map { part in
                        let files = try Meetings(root: config.meetingsRoot).read(summaryJobs[job] ?? path)
                        return part == .summary ? files.summary : files.todo
                    }
                }
                var previous = try partNow()
                try await downloads.ensureModel()
                var draft: SummaryDraft
                repeat {
                    // The meeting's voices were named meanwhile: the transcript is read again with its new
                    // names, and what's there now is what they were just put into.
                    if staleSummaries.remove(job) != nil { previous = try partNow() }
                    // Where the meeting is now: it may have been renamed or moved while the model downloaded.
                    draft = try await OatcakeCore.draftSummary(config, meeting: summaryJobs[job] ?? path, only: part, template: template)
                } while staleSummaries.contains(job)
                if let part, let previous {
                    try OatcakeCore.writeRegenerated(part, draft, config: config, meeting: summaryJobs[job] ?? path, previous: previous,
                                                     template: template)
                    regenerating.removeValue(forKey: summaryJobs[job] ?? path)
                    regeneratingWith.removeValue(forKey: summaryJobs[job] ?? path)
                } else {
                    try OatcakeCore.writeSummary(draft, config: config, meeting: summaryJobs[job] ?? path)
                    // The summary is there, but its to-dos couldn't be read from what the model sent.
                    if let problem = draft.todoProblem { todoProblems[summaryJobs[job] ?? path] = problem }
                }
            } catch {
                summaryErrors[summaryJobs[job] ?? path] = error.localizedDescription
            }
            let meeting = summaryJobs[job] ?? path
            summarising.remove(meeting)
            summaryJobs.removeValue(forKey: job)
            if summaryAgain.remove(job) != nil { writeSummary(meeting, only: .summary) }
            refresh()
        }
    }

    /// Draft for Sharing: the meeting's summary and to-dos written again for other people, with the
    /// instructions in Settings and `request` for this draft alone, in place of any draft there was.
    /// The sheet that asks for `request` has said so already. The old draft stays until the new one
    /// is ready, and stays if it fails or is edited meanwhile.
    func draftForSharing(_ path: String, request: String) {
        guard !drafting.contains(path), !summarising.contains(path) else { return }
        drafting.insert(path)
        draftErrors.removeValue(forKey: path)
        draftRequests[path] = request
        let job = UUID()
        draftJobs[job] = path
        let config = config
        Task {
            do {
                // What's there now: if it's edited by the time the model is done, it isn't replaced.
                let previous = try Meetings(root: config.meetingsRoot).read(path).draft
                try await downloads.ensureModel()
                let draft = try await OatcakeCore.draftForSharing(config, meeting: draftJobs[job] ?? path, request: request)
                try OatcakeCore.writeDraftForSharing(draft, config: config, meeting: draftJobs[job] ?? path, previous: previous)
                draftRequests.removeValue(forKey: draftJobs[job] ?? path)
            } catch {
                draftErrors[draftJobs[job] ?? path] = error.localizedDescription
            }
            drafting.remove(draftJobs[job] ?? path)
            draftJobs.removeValue(forKey: job)
            refresh()
        }
    }

    struct Job: Identifiable {
        enum Status { case processing, review, failed }
        var rec: Recording
        var status: Status
        var step: Int
        var id: String { rec.id }
    }

    var list: [Job] {
        pending.sorted { $0.startedAt > $1.startedAt }.map { rec in
            let p = progress[rec.id]
            return Job(rec: rec, status: p?.error != nil ? .failed : rec.state == .processed && !analysing.contains(rec.id) ? .review : .processing,
                       step: p?.stage?.number ?? 1)
        }
    }

    /// The Dock badge counts what's waiting for you: recordings to review, or that failed.
    func updateBadge() {
        let waiting = list.filter { $0.status != .processing }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }
}

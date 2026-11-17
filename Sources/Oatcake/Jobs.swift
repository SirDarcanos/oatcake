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
final class Jobs {
    /// What this part asks of the app around it.
    var app = AppServices()
    /// The language model: summaries wait for it, and name suggestions start it downloading.
    private let downloads: ModelDownloads
    private var config: Config { app.config() }
    private func toast(_ text: String, isError: Bool = false) { app.toast(text, isError) }
    private func refresh() { app.refresh() }

    var pending: [Recording] = []
    var progress: [String: JobProgress] = [:]
    /// Meetings whose summary is being written now, and why the last attempt failed, by path.
    var summarising = Set<String>()
    var summaryErrors: [String: String] = [:]
    /// What Regenerate is writing again, by path; kept after a failure, so Try again knows what to retry.
    var regenerating: [String: SummaryPart] = [:]
    /// Where each meeting being summarised lives now: it can be renamed or moved while the model writes.
    private var summaryJobs: [UUID: String] = [:]
    var reviewDrafts: [String: ReviewDraft] = [:]
    /// Meetings whose to-dos couldn't be read from the model's reply, and why, by path.
    var todoProblems: [String: String] = [:]
    private var analysing = Set<String>()
    /// The analysis helper running for each recording, and the work around it (which goes on to
    /// suggest names), so discarding a recording stops both.
    private var helpers: [String: ChildProcess.Handle] = [:]
    private var analyses: [String: Task<Void, Never>] = [:]
    private var autoStarted = Set<String>()
    /// One at a time: two clear-ups at once could both be writing the same meeting's audio.
    private let tidying = DispatchQueue(label: "oatcake.tidy-saved", qos: .utility)

    init(downloads: ModelDownloads) {
        self.downloads = downloads
    }

    /// Whether any call is being analysed now.
    var isAnalysingAny: Bool { !analysing.isEmpty }

    /// Recordings waiting to be processed start straight away, in the background.
    func startWaiting() {
        for rec in pending where rec.state == .recorded && !autoStarted.contains(rec.id) {
            autoStarted.insert(rec.id)
            analyse(rec.id)
        }
    }

    /// A folder or meeting has been renamed or moved: `remap` gives a path's new place.
    func moved(_ remap: (String) -> String) {
        // A summary on its way follows the meeting to where it is now.
        summarising = Set(summarising.map(remap))
        summaryJobs = summaryJobs.mapValues(remap)
        summaryErrors = Dictionary(summaryErrors.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        regenerating = Dictionary(regenerating.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        todoProblems = Dictionary(todoProblems.map { (remap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        // A recording waiting in Who's who is still saved into the folder it was set to, wherever that is now.
        reviewDrafts = reviewDrafts.mapValues { draft in with(draft) { $0.folder = remap($0.folder) } }
    }

    func analyse(_ id: String) {
        guard let rec = Recordings.get(id), !analysing.contains(id) else { return }
        analysing.insert(id)
        progress[id] = JobProgress(stage: progress[id]?.stage)
        analyses[id] = Task {
            // Steps arrive as they happen; the outcome is read from the full output once it exits.
            let result = try? await ChildProcess.run(Bundle.main.executableURL!, [HelperMode.analyse, rec.dir.path], onStart: { process in
                Task { @MainActor in self.helpers[id] = process }
            }, onLine: { line in
                guard let p = try? JSONDecoder().decode(AnalysisProgress.self, from: Data(line.utf8)), p.stage != nil else { return }
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
                    outcome = AnalysisProgress(error: "Analysis stopped (code \(result?.status ?? -1))\(detail)", failure: .helperStopped)
                }
            }
            // Step 5, here rather than in the helper: the language model is the app's to run. A model
            // that's still downloading isn't waited for; the names can be typed.
            if outcome?.done == true, Recordings.get(id) != nil, !Task.isCancelled, hasUnnamedVoices(rec.dir) {
                progress[id] = JobProgress(stage: .suggestingNames)
                if let chosenModel = downloads.chosenModel, !LocalModels.isDownloaded(chosenModel) { downloads.downloadModel(chosenModel) }
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
        tidying.async { Recordings.tidySaved(meetingsRoot: root) }
    }

    /// Regenerate summary or Regenerate to-dos: asks first, as it replaces what's there. The old one
    /// stays until the new one is written.
    func regenerate(_ part: SummaryPart, _ path: String) {
        guard !summarising.contains(path) else { return }
        let confirmation = part == .summary
            ? Confirmation(title: "Regenerate this summary?",
                           text: "It’s written again with your current instructions in Settings and replaces this summary, including any edits. Your transcript, notes and to-dos are kept.",
                           ok: "Regenerate summary", cancel: "Cancel") { [self] in writeSummary(path, only: .summary) }
            : Confirmation(title: "Regenerate these to-dos?",
                           text: "They’re written again with your current instructions in Settings and replace these to-dos, including any you’ve ticked, added or edited. Your transcript, notes and summary are kept.",
                           ok: "Regenerate to-dos", cancel: "Cancel") { [self] in writeSummary(path, only: .todos) }
        app.confirm(confirmation)
    }

    /// Writes a saved meeting's summary and to-dos in the background: after every save, and from
    /// Write summary when an earlier attempt couldn't reach the model. With `only`, that one part is
    /// written again in place of what's there (Regenerate).
    func writeSummary(_ path: String, only part: SummaryPart? = nil) {
        guard !summarising.contains(path) else { return }
        summarising.insert(path)
        summaryErrors.removeValue(forKey: path)
        if part != .summary { todoProblems.removeValue(forKey: path) }
        regenerating[path] = part
        let job = UUID()
        summaryJobs[job] = path
        let config = config
        Task {
            do {
                // What's there now: if it's changed by the time the model is done, it isn't replaced.
                let previous = try part.map { part in
                    let files = try Meetings(root: config.meetingsRoot).read(path)
                    return part == .summary ? files.summary : files.todo
                }
                try await downloads.ensureModel()
                // Where the meeting is now: it may have been renamed or moved while the model downloaded.
                let draft = try await OatcakeCore.draftSummary(config, meeting: summaryJobs[job] ?? path, only: part)
                if let part, let previous {
                    try OatcakeCore.writeRegenerated(part, draft, config: config, meeting: summaryJobs[job] ?? path, previous: previous)
                    regenerating.removeValue(forKey: summaryJobs[job] ?? path)
                } else {
                    try OatcakeCore.writeSummary(draft, config: config, meeting: summaryJobs[job] ?? path)
                    // The summary is there, but its to-dos couldn't be read from what the model sent.
                    if let problem = draft.todoProblem { todoProblems[summaryJobs[job] ?? path] = problem }
                }
            } catch {
                summaryErrors[summaryJobs[job] ?? path] = error.localizedDescription
            }
            summarising.remove(summaryJobs[job] ?? path)
            summaryJobs.removeValue(forKey: job)
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

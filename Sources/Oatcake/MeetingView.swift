import OatcakeCore
import SwiftUI

/// Remembered across meetings, so you can step through meetings on the same tab and view. The tab
/// is kept from one launch to the next too.
@MainActor private enum Remembered {
    static var tab: MeetingTab {
        get { MeetingTab.last }
        set { MeetingTab.last = newValue }
    }
    static var markdown = false
}

/// How saving what's typed is going, for the toolbar.
enum SaveStatus {
    /// Nothing typed since the view was opened or switched.
    case quiet
    case saving, saved, failed
    /// A to-do was ticked or added.
    case todo

    var text: String {
        switch self {
        case .quiet: "Saves as you type"
        case .saving: "Saving…"
        case .saved: "Saved"
        case .failed: "Couldn’t save"
        case .todo: "Saved"
        }
    }
}

enum FileKey: Hashable, CaseIterable {
    case summary, transcript, notes, todos, draft
    var file: MeetingFile {
        switch self {
        case .summary: .summary
        case .transcript: .transcript
        case .notes: .notes
        case .todos: .todo
        case .draft: .draft
        }
    }
}

struct MeetingView: View {
    @Environment(AppModel.self) var model
    @Environment(\.undoManager) private var undoManager
    let node: TreeNode
    let jump: Jump?

    @ViewState var files: [FileKey: String]?
    @ViewState var recordingAudio: URL?
    @ViewState var playback = RecordingPlayback()
    @ViewState var meta = MeetingMeta()
    @ViewState private var loadError = ""
    @ViewState var tab = Remembered.tab
    @ViewState var markdown = Remembered.markdown
    @ViewState var status = SaveStatus.quiet
    /// The transcript as parsed lines, and as the rows drawn: worked out when the file is read or
    /// edited, not each time the view is redrawn.
    @ViewState private var transcriptLines: [TranscriptLine] = []
    @ViewState private var rows: [Row] = []
    /// The speakers Rename speakers… offers: only in a transcript Oatcake wrote.
    @ViewState var speakers: [MeetingSpeaker] = []
    @ViewState private var renamingSpeakers = false
    @ViewState private var askingForDraft = false
    /// The transcript's Markdown has been typed in since it was last parsed.
    @ViewState private var transcriptEdited = false
    @ViewState var flash = -1
    @ViewState var newTodo = ""
    @ViewState private var saveTask: Task<Void, Never>?
    /// Counts reads of the files, and writes to them from here: a read that lands after a later one,
    /// or after a write, is older than what's shown, and is dropped.
    @ViewState private var loads = 0
    /// The summary has just been written and is being read here: its editors stay closed till it is,
    /// so nothing is typed over the text from before.
    @ViewState private var readingSummary = false
    @ViewState private var arrived = false
    /// Whether the tab has been checked against this meeting yet (the view is made afresh for each meeting).
    @ViewState private var tabChecked = false
    @ViewState var finding = false
    @ViewState var query = ""
    @ViewState var match = 0
    @FocusState var findFocused: Bool
    /// This view, as the menus outside it know it.
    @ViewState var viewID = UUID()
    @AppStorage(TextScale.key) private var textScale = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// View › Bigger Text and Smaller Text: how big the note's own text is drawn.
    var scale: CGFloat { TextScale.clamped(textScale) }

    var path: String { node.path }

    var body: some View {
        Group {
            if !loadError.isEmpty {
                VStack(spacing: 10) {
                    Text("Couldn’t open this meeting").font(.headline)
                    Text(loadError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("Try again") { load() }
                        Button("Show in Finder") { model.library.reveal(path) }
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let files {
                content(files)
            } else {
                Color.clear
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $renamingSpeakers) {
            RenameSpeakersSheet(speakers: speakers, todos: model.config.todosEnabled) { renames in
                model.library.renameSpeakers(path, renames)
            }
        }
        .sheet(isPresented: $askingForDraft) {
            DraftForSharingSheet(replacing: !(files?[.draft] ?? "").trimmed.isEmpty, todos: model.config.todosEnabled) { request in
                model.jobs.draftForSharing(path, request: request)
                switchTab(.draft)
            }
        }
        .onAppear {
            if let jump {
                tab = jump.tab
                // Opened from search: its words in Find, marked wherever they are in the meeting. Read
                // as laid out, as ⌘F does: the Markdown editors mark nothing.
                if !jump.words.isEmpty {
                    query = jump.words.joined(separator: " ")
                    finding = true
                    markdown = false
                    Remembered.markdown = false
                }
            }
            load()
        }
        .onChange(of: model.library.diskVersion) { load() }
        .onChange(of: model.jobs.summarising.contains(path)) { was, now in
            guard was, !now else { return }
            readingSummary = true
            load()
        }
        // The menu bar's Meeting menu, Find and View's tabs, and the other menus with this meeting's commands.
        .onChange(of: model.meetingRequest) { if let request = model.meetingRequest { perform(request.command) } }
        .onChange(of: menuState, initial: true) { model.meetingShowing = menuState }
        .onDisappear {
            if model.meetingShowing?.view == viewID { model.meetingShowing = nil }
            flush()
            // Said while you're here; it isn't kept.
            model.jobs.todoProblems.removeValue(forKey: path)
        }
    }

    // MARK: Loading and saving

    /// Reads the meeting's files and parses its transcript, off the main actor. A change on disk
    /// (Finder, another editor, our own save) replaces what's shown, except what's typed here and still
    /// waiting to be saved: that stays as it's typed.
    private func load() {
        loads += 1
        let asked = loads
        let meetings = model.library.meetings, path = path, myName = model.config.myName
        Task {
            let read = await Task.detached { () -> Result<(MeetingFiles, URL?, ParsedTranscript), Error> in
                Result {
                    let m = try meetings.read(path)
                    return (m, meetings.recordingAudio(path), Self.parsed(m.transcript, myName: myName))
                }
            }.value
            guard asked == loads else { return }
            // The newest read: if the summary has just been written, it began after that.
            readingSummary = false
            switch read {
            case .success(let (m, audio, transcript)):
                recordingAudio = audio
                let typed = model.edits.texts(in: path)
                let onDisk: [FileKey: String] = [.summary: m.summary, .transcript: m.transcript, .notes: m.notes, .todos: m.todo, .draft: m.draft]
                files = Dictionary(uniqueKeysWithValues: FileKey.allCases.map { ($0, typed[$0.file] ?? onDisk[$0] ?? "") })
                // Arriving on Draft for Sharing from a meeting that had one, at one that doesn't. Only on
                // arrival: a draft emptied here, to be written again by hand, keeps its tab meanwhile.
                if !tabChecked {
                    tabChecked = true
                    if tab == .draft && !hasDraft { tab = .summary }
                }
                if let edited = typed[.transcript] {
                    readTranscript(edited)
                } else {
                    (transcriptLines, speakers, rows) = transcript
                }
                meta = m.meta
                loadError = ""
                if let stamp = jump?.stamp, !arrived {
                    arrived = true
                    // Arriving from the To-dos page with a time: jump there once the transcript has loaded.
                    DispatchQueue.main.async { self.jumpTo(stamp) }
                }
                // Typed here earlier and not written yet (its save failed, say): it's tried again.
                if !typed.isEmpty, status == .quiet { saveSoon() }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }

    /// Edits save 600 ms after the last keystroke, and straight away when leaving the meeting.
    private func write(_ key: FileKey, _ content: String) {
        model.edits.typed(content, in: path, key.file, before: files?[key] ?? "")
        files?[key] = content
        if key == .transcript { transcriptEdited = true }
        saveSoon()
    }

    private func saveSoon() {
        status = .saving
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { flush() }
        }
    }

    func flush() {
        saveTask?.cancel()
        // Every way out of the Markdown editor comes through here, so the rows are right when they're next shown.
        if transcriptEdited {
            transcriptEdited = false
            readTranscript(files?[.transcript] ?? "")
        }
        let waiting = model.edits.texts(in: path).count
        let outcomes = model.saveEdits(in: path)
        // Written (here or beside): a read still on its way has the files as they were before.
        if model.edits.texts(in: path).count < waiting {
            loads += 1
            // The read the summary's editors wait for is one of those dropped: another takes its place.
            if readingSummary { load() }
        }
        if model.edits.isWaiting(in: path) {
            status = .failed
        } else if !outcomes.isEmpty {
            // A file had changed meanwhile, so what was typed went beside it (saveEdits says so): the
            // file as it is now is shown.
            status = .quiet
            load()
        } else if status != .todo && status != .quiet {
            status = .saved
        }
    }

    /// A to-do added on the Summary tab. What's shown changes at once; the file is changed as it is
    /// now rather than written over with what's shown, so to-dos that have arrived since this was
    /// read (the summary's own, say) are kept.
    func changeTodos(shown: String, _ change: () throws -> Bool) {
        files?[.todos] = shown
        do {
            guard try change() else {
                // It isn't in the file as it's shown here: nothing was ticked, and the file is read again.
                model.toast(todoChangedMessage)
                return load()
            }
            todosSaved()
        } catch {
            model.toast(error.localizedDescription, isError: true)
            load()
        }
    }

    /// A tick here, as everywhere (Library.tick): what's shown is the file as it is afterwards, or,
    /// when nothing was ticked, the meeting read again.
    func tick(_ todo: Todo) {
        model.library.tick(path, todo, undo: undoManager) { [files = $files] text in
            guard let text else { return load() }
            files.wrappedValue?[.todos] = text
            todosSaved()
        }
    }

    private func todosSaved() {
        // A read still on its way has the to-dos as they were before.
        loads += 1
        status = .todo
        Task {
            try? await Task.sleep(for: .seconds(2))
            if status == .todo { status = .quiet }
        }
    }

    /// The meeting has a draft for sharing, or one is being written or failed to be: its tab shows.
    private var hasDraft: Bool {
        !(files?[.draft] ?? "").trimmed.isEmpty || model.jobs.drafting.contains(path) || model.jobs.draftErrors[path] != nil
    }

    /// The Draft for Sharing tab shows while there's a draft, and while you're on it.
    var showsDraftTab: Bool { hasDraft || tab == .draft }

    var tabs: [MeetingTab] { showsDraftTab ? MeetingTab.allCases : MeetingTab.allCases.filter { $0 != .draft } }

    func switchTab(_ t: MeetingTab) {
        flush()
        tab = t
        Remembered.tab = t
    }

    func jumpTo(_ stamp: String) {
        let t = seconds(stamp)
        var index = 0
        for (i, l) in transcriptLines.enumerated() where l.at <= t { index = i }
        flush()
        markdown = false
        Remembered.markdown = false
        switchTab(.transcript)
        flash = index
    }

    /// A command from this meeting's menu, or one outside it.
    func perform(_ command: MeetingCommand) {
        switch command {
        case .tab(let t):
            if tabs.contains(t) { switchTab(t) }
        case .find:
            // On the tab showing, as it's laid out: the Markdown editors mark nothing.
            if markdown {
                flush()
                markdown = false
                Remembered.markdown = false
            }
            finding = true
            findFocused = true
        case .findNext, .findPrevious:
            step(command == .findNext ? 1 : -1, matches(in: rows))
        case .draftForSharing:
            // Edits to the summary, to-dos or draft are saved first: the draft is written from them.
            flush()
            guard !model.edits.isWaiting(in: path) else { return }
            askingForDraft = true
        case .regenerate(let part, let template):
            regenerate(part, template: template)
        case .renameSpeakers:
            // A failed save keeps its text pending; renaming then would have it written back over the new names.
            flush()
            guard !model.edits.isWaiting(in: path) else { return }
            renamingSpeakers = true
        case .copy:
            copy(tab.contents(todos: model.config.todosEnabled))
        }
    }

    /// Read or Edit: how the tab below is shown, laid out or as its Markdown. It sits at the top right, beside the title.
    private var viewSwitch: some View {
        Picker("View", selection: Binding(get: { markdown }, set: { flush(); markdown = $0; Remembered.markdown = $0; status = .quiet })) {
            Text("Read").tag(false)
            Text("Edit").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Read this tab as it’s laid out, or edit its Markdown")
    }

    // MARK: Content

    var granola: Bool { meta.source == "granola" || node.granola }

    private func readTranscript(_ text: String) {
        (transcriptLines, speakers, rows) = Self.parsed(text, myName: model.config.myName)
    }

    private typealias ParsedTranscript = (lines: [TranscriptLine], speakers: [MeetingSpeaker], rows: [Row])

    /// Parses the transcript for showing. Granola labels your track "Microphone"; the call side carries
    /// Granola's own guesses at names. Its CSV export has transcripts without times or names: those
    /// are plain paragraphs, with no speaker.
    nonisolated private static func parsed(_ text: String, myName: String) -> ParsedTranscript {
        let lines = parseTranscript(text).map { l in
            var l = l
            if l.speaker == "Microphone" { l.speaker = myName } else if l.speaker == "System audio" { l.speaker = "Call audio" }
            return l
        }
        let rows = lines.isEmpty ? text.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }.map { Row(text: $0) }
            : lines.map { Row(speaker: $0.speaker, stamp: $0.stamp, at: $0.at, text: $0.text) }
        return (lines, meetingSpeakers(text), rows)
    }

    private func content(_ files: [FileKey: String]) -> some View {
        // Find marks its words on any tab as it's read; on the transcript it also steps through the lines.
        let stepping = tab == .transcript
        let found = finding && stepping && !markdown ? matches(in: rows) : []
        return VStack(spacing: 0) {
            if finding && !markdown {
                findBar(found, stepping: stepping)
                Divider()
            }
            scrolling(files, rows: rows, found: found)
        }
    }

    private func scrolling(_ files: [FileKey: String], rows: [Row], found: [Int]) -> some View {
        let current = found.indices.contains(match) ? found[match] : nil
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 16) {
                        PageTitle(text: meta.title ?? meetingTitle(node)).frame(maxWidth: .infinity, alignment: .leading)
                        viewSwitch.padding(.top, 5)
                    }
                    Text(metaLine).foregroundStyle(.secondary).padding(.top, 8)
                    RecordingPlayerView(url: recordingAudio, playback: playback) { model.library.reveal(path) }
                    if granola {
                        Notice(tone: .grey) { Text(granolaNotice(files)) }.padding(.top, 14)
                    }
                    if let id = meta.recording, model.jobs.unchecked.contains(where: { $0.id == id }) {
                        uncheckedNotice(id, unnamed: (meta.participants ?? []).contains { $0.range(of: #"^Voice \d+$"#, options: .regularExpression) != nil })
                            .padding(.top, 14)
                    }
                    Spacer().frame(height: 22)
                    if tab == .summary, let part = model.jobs.regenerating[path] {
                        let what = part == .summary ? "summary" : "to-dos"
                        if model.jobs.summarising.contains(path) {
                            Notice(tone: .blue) {
                                Text("Regenerating the \(what)…").fontWeight(.semibold)
                                Text(part == .summary ? "Your summary stays until the new one is ready." : "Your to-dos stay until the new ones are ready.")
                            }.padding(.bottom, 16)
                        } else if let error = model.jobs.summaryErrors[path] {
                            Notice(tone: .red) {
                                ModelError(raw: error, prefix: "Couldn’t regenerate the \(what). ")
                                Text(part == .summary ? "Your previous summary was kept." : "Your previous to-dos were kept.")
                                HStack(spacing: 10) {
                                    Button("Try again") { regenerate(part, template: model.jobs.regeneratingWith[path] ?? .meetings) }
                                        .disabled((files[.transcript] ?? "").trimmed.isEmpty)
                                    SettingsPaneLink(pane: .models, title: "Open Settings").buttonStyle(.link)
                                }
                                .padding(.top, 6)
                            }.padding(.bottom, 16)
                        }
                    }
                    if tab == .draft { draftNotice }
                    if markdown {
                        markdownEditors(files)
                    } else {
                        switch tab {
                        case .summary: summary(files)
                        case .transcript: transcript(rows, current: current)
                        case .notes: notes(files)
                        case .draft: draft(files)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 16)
                .padding(.bottom, 120)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: current) {
                if let current { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.33)) } }
            }
            .onChange(of: flash) {
                guard flash >= 0 else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(flash, anchor: UnitPoint(x: 0, y: 0.33)) }
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    withAnimation { flash = -1 }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == stampScheme {
                jumpTo(String(url.absoluteString.dropFirst(stampScheme.count + 1)))
                return .handled
            }
            if let rel = meetingPath(from: url) {
                model.openMeeting(rel)
                return .handled
            }
            return url.scheme == "https" || url.scheme == "http" ? .systemAction : .discarded
        })
    }

    var metaLine: String {
        let date = parseISO(meta.startedAt) ?? meetingDate(node)
        let length = parseISO(meta.endedAt).flatMap { end in parseISO(meta.startedAt).map { end.timeIntervalSince($0) } }
        let withWhom = (meta.participants ?? []).filter { $0 != model.config.myName }
            .map { $0.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression) }
        return [date.map { longDay($0) }, date.map { timeOfDay($0) }, length.map(longDuration),
                !granola && !withWhom.isEmpty ? "with \(withWhom.joined(separator: ", "))" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Saved straight after the call, without anyone checking who's who (Settings › General › After a call).
    /// `unnamed`: some of its voices weren't recognised, so they're "Voice 1", "Voice 2"… for now.
    private func uncheckedNotice(_ id: String, unnamed: Bool) -> some View {
        // Amber, not blue: blue notices carry a spinner, for work in progress.
        Notice(tone: .amber) {
            Text("Saved without checking who’s who").fontWeight(.semibold)
            Text(unnamed
                 ? "Voices Oatcake didn’t recognise are “Voice 1”, “Voice 2”… Name them and this meeting’s transcript, summary and to-dos are updated."
                 : "Oatcake recognised every voice from before and used those names. Change one and this meeting’s transcript, summary and to-dos are updated.")
            HStack(spacing: 10) {
                Button("Check who’s who…") {
                    flush()
                    model.selection = .job(id)
                }
                Button("Keep these names…") {
                    model.confirm(Confirmation(title: "Keep these names?",
                                               text: "The recording’s voice clips are deleted for good, so its voices can’t be named later. The meeting stays as it is.",
                                               ok: "Keep these names", cancel: "Cancel") { model.jobs.keepAsIs(id) })
                }
            }
            .padding(.top, 6)
        }
    }

    private func granolaNotice(_ files: [FileKey: String]) -> String {
        let transcript = files[.transcript] ?? ""
        let plain = transcriptLines.isEmpty && !transcript.trimmed.isEmpty
        // The raw file: parsing turns "System audio (Jane)" into plain "Jane".
        let guessed = transcript.range(of: #"(?m)^\[[\d:]+\]\s+System audio \("#, options: .regularExpression) != nil
        let sidesOnly = transcript.range(of: #"(?m)^\[[\d:]+\]\s+System audio:"#, options: .regularExpression) != nil
        return ["Imported from Granola.",
                (files[.notes] ?? "").trimmed.isEmpty ? "It didn’t keep your notes." : nil,
                guessed ? "The names on the call side of its transcript are Granola’s own guesses."
                    : sidesOnly ? "Its transcript only tells your side of the call from everyone else’s." : nil,
                plain ? "Its transcript doesn’t say who said what." : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func markdownEditors(_ files: [FileKey: String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(editorKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(folderPath(path)) › \(key.file.rawValue)", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                    // While the model is writing these two files they aren't for typing in: what's typed
                    // and what's written would overwrite each other.
                    if model.jobs.drafting.contains(path), key == .draft {
                        Text("The draft for sharing is being written. This can be edited once it’s here.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
                    } else if model.jobs.summarising.contains(path) || readingSummary, key == .summary || key == .todos {
                        Text("The summary is being written. This can be edited once it’s here.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: key == .todos ? 70 : 120, alignment: .topLeading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
                    } else {
                        // Read live state so the binding can return the new text immediately after typing.
                        TextEditor(text: Binding(get: { self.files?[key] ?? "" }, set: { write(key, $0) }))
                            .font(.system(size: 12.5 * scale, design: .monospaced))
                            .scrollDisabled(true)
                            .frame(minHeight: key == .todos ? 70 : 300)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line))
                            .overlay(alignment: .topLeading) {
                                if key == .todos && (files[key] ?? "").isEmpty {
                                    Text("- [ ] What to do — Owner — due Fri, Oct 30 — [12:34]")
                                        .font(.system(size: 12.5 * scale, design: .monospaced)).foregroundStyle(.tertiary)
                                        .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
        }
    }

    /// The files the Markdown view edits on the tab you're on.
    private var editorKeys: [FileKey] {
        switch tab {
        case .summary: model.config.todosEnabled ? [.todos, .summary] : [.summary]
        case .transcript: [.transcript]
        case .notes: [.notes]
        case .draft: [.draft]
        }
    }
}

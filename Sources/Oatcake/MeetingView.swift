import OatcakeCore
import SwiftUI

/// Remembered across meetings, so you can step through meetings on the same tab and view.
@MainActor private enum Remembered {
    static var tab = MeetingTab.summary
    static var markdown = false
}

/// How saving what's typed is going, for the toolbar.
private enum SaveStatus {
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
        case .todo: "Saved to todo.md"
        }
    }
}

private enum FileKey: Hashable {
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
    @Environment(AppModel.self) private var model
    let node: TreeNode
    let jump: Jump?

    @ViewState private var files: [FileKey: String]?
    @ViewState private var meta = MeetingMeta()
    @ViewState private var loadError = ""
    @ViewState private var tab = Remembered.tab
    @ViewState private var markdown = Remembered.markdown
    @ViewState private var status = SaveStatus.quiet
    /// The transcript as parsed lines, and as the rows drawn: worked out when the file is read or
    /// edited, not each time the view is redrawn.
    @ViewState private var transcriptLines: [TranscriptLine] = []
    @ViewState private var rows: [Row] = []
    /// The speakers Rename speakers… offers: only in a transcript Oatcake wrote.
    @ViewState private var speakers: [MeetingSpeaker] = []
    @ViewState private var renamingSpeakers = false
    @ViewState private var askingForDraft = false
    /// The transcript's Markdown has been typed in since it was last parsed.
    @ViewState private var transcriptEdited = false
    @ViewState private var flash = -1
    @ViewState private var newTodo = ""
    @ViewState private var pending: [FileKey: String] = [:]
    @ViewState private var saveTask: Task<Void, Never>?
    @ViewState private var arrived = false
    /// Whether the tab has been checked against this meeting yet (the view is made afresh for each meeting).
    @ViewState private var tabChecked = false
    @ViewState private var finding = false
    @ViewState private var query = ""
    @ViewState private var match = 0
    @ViewState private var copied = false
    @FocusState private var findFocused: Bool
    @AppStorage(TextScale.key) private var textScale = 1.0

    /// View › Bigger Text and Smaller Text: how big the note's own text is drawn.
    private var scale: CGFloat { TextScale.clamped(textScale) }

    private var path: String { node.path }

    var body: some View {
        Group {
            if !loadError.isEmpty {
                Text(loadError).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let jump { tab = jump.tab }
            load()
        }
        .onChange(of: model.library.diskVersion) { load() }
        // ⌘F: Find, on the transcript.
        .onChange(of: model.findRequest) {
            flush()
            markdown = false
            Remembered.markdown = false
            switchTab(.transcript)
            finding = true
            findFocused = true
        }
        .onDisappear {
            flush()
            // Said while you're here; it isn't kept.
            model.jobs.todoProblems.removeValue(forKey: path)
        }
        .background {
            // ⌘1–⌘3 switch tabs, and ⌘4 to the draft for sharing in a meeting that has one.
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button("") { switchTab(t) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).hidden()
            }
        }
    }

    // MARK: Loading and saving

    /// A change on disk (Finder, another editor, our own save) only replaces the text when nothing
    /// typed here is still waiting to be saved.
    private func load() {
        guard pending.isEmpty else { return }
        do {
            let m = try model.library.readMeeting(path)
            files = [.summary: m.summary, .transcript: m.transcript, .notes: m.notes, .todos: m.todo, .draft: m.draft]
            // Arriving on Draft for Sharing from a meeting that had one, at one that doesn't. Only on
            // arrival: a draft emptied here, to be written again by hand, keeps its tab meanwhile.
            if !tabChecked {
                tabChecked = true
                if tab == .draft && !hasDraft { tab = .summary }
            }
            readTranscript(m.transcript)
            meta = m.meta
            loadError = ""
            if let stamp = jump?.stamp, !arrived {
                arrived = true
                // Arriving from the To-dos page with a time: jump there once the transcript has loaded.
                DispatchQueue.main.async { self.jumpTo(stamp) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Edits save 600 ms after the last keystroke, and straight away when leaving the meeting.
    private func write(_ key: FileKey, _ content: String, now: Bool = false) {
        files?[key] = content
        pending[key] = content
        if key == .transcript { transcriptEdited = true }
        status = now ? .todo : .saving
        saveTask?.cancel()
        saveTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(600)) }
            if !Task.isCancelled { flush() }
        }
    }

    private func flush() {
        saveTask?.cancel()
        // Every way out of the Markdown editor comes through here, so the rows are right when they're next shown.
        if transcriptEdited {
            transcriptEdited = false
            readTranscript(files?[.transcript] ?? "")
        }
        for (key, content) in pending {
            do {
                try model.library.writeMeetingFile(path, key.file, content)
                // Typing that arrived during the save stays waiting.
                if pending[key] == content { pending.removeValue(forKey: key) }
            } catch {
                status = .failed
                return
            }
        }
        if pending.isEmpty && status != .todo && status != .quiet { status = .saved }
        if status == .todo {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if status == .todo { status = .quiet }
            }
        }
    }

    /// A tick, or a to-do added, on the Summary tab. What's shown changes at once; the file is changed
    /// as it is now rather than written over with what's shown, so to-dos that have arrived since
    /// this was read (the summary's own, say) are kept.
    private func changeTodos(shown: String, _ change: () throws -> Bool) {
        files?[.todos] = shown
        do {
            guard try change() else {
                // It isn't in the file as it's shown here: nothing was ticked, and the file is read again.
                model.toast(todoChangedMessage)
                return load()
            }
            status = .todo
            Task {
                try? await Task.sleep(for: .seconds(2))
                if status == .todo { status = .quiet }
            }
        } catch {
            model.toast(error.localizedDescription, isError: true)
            load()
        }
    }

    /// The meeting has a draft for sharing, or one is being written or failed to be: its tab shows.
    private var hasDraft: Bool {
        !(files?[.draft] ?? "").trimmed.isEmpty || model.jobs.drafting.contains(path) || model.jobs.draftErrors[path] != nil
    }

    /// The Draft for Sharing tab shows while there's a draft, and while you're on it.
    private var showsDraftTab: Bool { hasDraft || tab == .draft }

    private var tabs: [MeetingTab] { showsDraftTab ? MeetingTab.allCases : MeetingTab.allCases.filter { $0 != .draft } }

    private func switchTab(_ t: MeetingTab) {
        flush()
        tab = t
        Remembered.tab = t
    }

    private func jumpTo(_ stamp: String) {
        let t = seconds(stamp)
        var index = 0
        for (i, l) in transcriptLines.enumerated() where l.at <= t { index = i }
        flush()
        markdown = false
        Remembered.markdown = false
        switchTab(.transcript)
        flash = index
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tab", selection: Binding(get: { tab }, set: { switchTab($0) })) {
                Text("Summary").tag(MeetingTab.summary).help("⌘1")
                Text("Transcript").tag(MeetingTab.transcript).help("⌘2")
                Text("My notes").tag(MeetingTab.notes).help("⌘3")
                if showsDraftTab { Text("Draft for Sharing").tag(MeetingTab.draft).help("⌘4") }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .automatic) {
            // How saving is going stays up here, in sight wherever the note is scrolled to.
            if markdown || status == .todo || status == .failed {
                HStack(spacing: 6) {
                    Text(status.text)
                        .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    if status == .failed { Button("Try again") { flush() }.buttonStyle(.link) }
                }
                .font(.callout)
            }
            if tab == .summary, !(files?[.summary] ?? "").trimmed.isEmpty {
                Menu {
                    if templates.isEmpty {
                        Button("Regenerate summary") { regenerate(.summary) }
                    } else {
                        // Ticked: what this meeting's summary is written with now.
                        let current = model.config.summaryTemplate(named: meta.template)?.name
                        Menu("Regenerate summary") {
                            Toggle("Default", isOn: Binding(get: { current == nil }, set: { _ in regenerate(.summary, template: .picked(nil)) }))
                            Divider()
                            ForEach(templates, id: \.name) { t in
                                Toggle(t.name, isOn: Binding(get: { current == t.name }, set: { _ in regenerate(.summary, template: .picked(t.name)) }))
                            }
                        }
                    }
                    if model.config.todosEnabled { Button("Regenerate to-dos") { regenerate(.todos) } }
                } label: {
                    // Named on the image too: a toolbar menu is read out by its image's name, "Refresh".
                    Label { Text("Regenerate") } icon: { Image(systemName: "arrow.clockwise").accessibilityLabel("Regenerate") }
                }
                    .accessibilityLabel("Regenerate")
                    .disabled(model.jobs.summarising.contains(path) || (files?[.transcript] ?? "").trimmed.isEmpty)
                    .help(model.config.todosEnabled
                          ? (templates.isEmpty ? "Write the summary or the to-dos again with the current instructions in Settings"
                             : "Write the summary (with a template, if you pick one) or the to-dos again")
                          : (templates.isEmpty ? "Write the summary again with the current instructions in Settings"
                             : "Write the summary again, with a template if you pick one"))
            }
            if tab == .summary || tab == .draft, !(files?[.summary] ?? "").trimmed.isEmpty {
                Button {
                    // Edits to the summary, to-dos or draft are saved first: the draft is written from them.
                    flush()
                    guard pending.isEmpty else { return }
                    askingForDraft = true
                } label: { Label("Draft for Sharing…", systemImage: "square.and.pencil") }
                    .disabled(model.jobs.summarising.contains(path) || model.jobs.drafting.contains(path))
                    .help(model.config.todosEnabled ? "Write this meeting’s summary and to-dos again for other people to read"
                          : "Write this meeting’s summary again for other people to read")
            }
            if canRenameSpeakers {
                Button {
                    // A failed save keeps its text pending; renaming then would have it written back over the new names.
                    flush()
                    guard pending.isEmpty else { return }
                    renamingSpeakers = true
                } label: { Label("Rename Speakers", systemImage: "person.2") }
                    .disabled(model.jobs.summarising.contains(path))
                    .help(model.config.todosEnabled ? "Change who’s who in this meeting: the names in its transcript, summary and to-dos"
                          : "Change who’s who in this meeting: the names in its transcript and summary")
            }
            let what = switch tab {
            case .summary: model.config.todosEnabled ? "summary and to-dos" : "summary"
            case .transcript: "transcript"
            case .notes: "notes"
            case .draft: "draft for sharing"
            }
            Button { copy() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy the \(what), formatted (as Markdown where only plain text can go)")
            ShareLink(item: shareText, subject: Text(meetingTitle(node))) { Label("Share", systemImage: "square.and.arrow.up") }
                .help("Send the \(what) with Mail, Messages or another app")
            Button { model.library.reveal(path) } label: { Label("Show in Finder", systemImage: "arrow.up.forward.square") }
                .help("Show this meeting’s folder in Finder")
        }
    }

    /// Rendered or Markdown: how the note below is shown. It sits at the top right of the note, beside its title.
    private var viewSwitch: some View {
        Picker("View", selection: Binding(get: { markdown }, set: { flush(); markdown = $0; Remembered.markdown = $0; status = .quiet })) {
            Text("Rendered").tag(false)
            Text("Markdown").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Read the note as it’s laid out, or edit its Markdown")
    }

    /// What Copy and Share take: the tab you're on, as Markdown under the meeting's title and date.
    private var shareText: String {
        let part = { (key: FileKey) in forReading(files?[key] ?? "").trimmed }
        var parts = ["# \(meetingTitle(node))", metaLine]
        switch tab {
        case .summary:
            if model.config.todosEnabled, !part(.todos).isEmpty { parts.append("## To-dos\n\n\(part(.todos))") }
            parts.append(part(.summary))
        case .transcript: parts.append(part(.transcript))
        case .notes: parts.append(part(.notes))
        case .draft: parts.append(part(.draft))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private func copy() {
        // Formatted for documents and mail, and the Markdown for anything that only takes plain text.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardHTML(shareText), forType: .html)
        pasteboard.setString(shareText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// A meeting saved without checking who's who has Name voices… instead, until Keep as is.
    private var canRenameSpeakers: Bool {
        guard !speakers.isEmpty else { return false }
        guard let id = meta.recording else { return true }
        return !model.jobs.unchecked.contains { $0.id == id }
    }

    // MARK: Content

    private var granola: Bool { meta.source == "granola" || node.granola }

    /// Parses the transcript for showing. Granola labels your track "Microphone"; the call side carries
    /// Granola's own guesses at names. Its CSV export has transcripts without times or names: those
    /// are plain paragraphs, with no speaker.
    private func readTranscript(_ text: String) {
        let lines = parseTranscript(text).map { l in
            var l = l
            if l.speaker == "Microphone" { l.speaker = model.config.myName } else if l.speaker == "System audio" { l.speaker = "Call audio" }
            return l
        }
        transcriptLines = lines
        speakers = meetingSpeakers(text)
        rows = lines.isEmpty ? text.components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }.map { Row(text: $0) }
            : lines.map { Row(speaker: $0.speaker, stamp: $0.stamp, text: $0.text) }
    }

    private func content(_ files: [FileKey: String]) -> some View {
        let found = finding && tab == .transcript && !markdown ? matches(in: rows) : []
        return VStack(spacing: 0) {
            if finding && tab == .transcript && !markdown {
                findBar(found)
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
                                    SettingsPaneLink(pane: "models", title: "Open Settings").buttonStyle(.link)
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
                .padding(.top, 28)
                .padding(.bottom, 120)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: current) {
                if let current { withAnimation { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.33)) } }
            }
            .onChange(of: flash) {
                guard flash >= 0 else { return }
                withAnimation { proxy.scrollTo(flash, anchor: UnitPoint(x: 0, y: 0.33)) }
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

    private var metaLine: String {
        let date = parseISO(meta.startedAt) ?? meetingDate(node)
        let length = parseISO(meta.endedAt).flatMap { end in parseISO(meta.startedAt).map { end.timeIntervalSince($0) } }
        let withWhom = (meta.participants ?? []).filter { $0 != model.config.myName }
            .map { $0.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression) }
        return [date.map { "\(weekday($0)), \(longDate($0))" }, date.map(hhmm), length.map(minutes),
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
                Button("Name voices…") {
                    flush()
                    model.selection = .job(id)
                }
                Button("Keep as is") { model.jobs.keepAsIs(id) }
                    .help("Keep these names. The recording’s voice clips are deleted, so its voices can’t be named later.")
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
                    } else if model.jobs.summarising.contains(path), key == .summary || key == .todos {
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

    /// The draft for sharing being written, or why it couldn't be. A draft already there stays meanwhile.
    @ViewBuilder private var draftNotice: some View {
        if model.jobs.drafting.contains(path) {
            Notice(tone: .blue) {
                Text("Writing the draft for sharing…").fontWeight(.semibold)
                Text((files?[.draft] ?? "").trimmed.isEmpty ? "It’s written from the summary\(model.config.todosEnabled ? " and to-dos" : "")."
                     : "The draft that’s here stays until the new one is ready.")
            }.padding(.bottom, 16)
        } else if let error = model.jobs.draftErrors[path] {
            Notice(tone: .red) {
                ModelError(raw: error, prefix: "Couldn’t write the draft for sharing. ")
                if !(files?[.draft] ?? "").trimmed.isEmpty { Text("The draft that was here was kept.") }
                HStack(spacing: 10) {
                    Button("Try again") {
                        flush()
                        guard pending.isEmpty else { return }
                        model.jobs.draftForSharing(path, request: model.jobs.draftRequests[path] ?? "")
                    }
                    .disabled((files?[.summary] ?? "").trimmed.isEmpty || model.jobs.summarising.contains(path))
                    SettingsPaneLink(pane: "models", title: "Open Settings").buttonStyle(.link)
                    // Put aside: without a draft there's nothing else on this tab, so it goes too.
                    Button("Dismiss") {
                        model.jobs.draftErrors.removeValue(forKey: path)
                        model.jobs.draftRequests.removeValue(forKey: path)
                        if (files?[.draft] ?? "").trimmed.isEmpty { switchTab(.summary) }
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 6)
            }.padding(.bottom, 16)
        }
    }

    private func draft(_ files: [FileKey: String]) -> some View {
        let text = files[.draft] ?? ""
        return Group {
            if !text.trimmed.isEmpty {
                MarkdownView(markdown: text, fontSize: 14 * scale)
            } else if !model.jobs.drafting.contains(path) && model.jobs.draftErrors[path] == nil {
                Text("No draft for sharing in this meeting.").foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ files: [FileKey: String]) -> some View {
        let todoText = files[.todos] ?? ""
        let todos = parseTodos(todoText)
        let open = todos.filter { !$0.done }.count
        let summary = forReading(files[.summary] ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            // Turned off in Settings › General: no checklist, and nothing to say about one.
            if model.config.todosEnabled { todoList(todos, todoText: todoText, open: open) }
            if summary.trimmed.isEmpty && !(files[.transcript] ?? "").trimmed.isEmpty {
                summaryLater
            } else if summary.trimmed.isEmpty {
                Text("No summary for this meeting.").foregroundStyle(.secondary)
            } else {
                MarkdownView(markdown: summary, fontSize: 14 * scale)
            }
        }
    }

    /// The meeting's to-dos (todo.md), to tick and add to, above its summary.
    private func todoList(_ todos: [Todo], todoText: String, open: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The summary was written but the to-dos couldn't be read from the model's reply.
            if let problem = model.jobs.todoProblems[path] {
                Notice(tone: .amber) { Text(problem) }.padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 8) {
                // No to-dos yet: just the field to add one.
                if !todos.isEmpty { SectionLabel(text: "To-dos\(open > 0 ? " · \(open) open" : "")") }
                ForEach(todos, id: \.line) { t in
                    HStack(alignment: .top, spacing: 10) {
                        TodoCheckbox(checked: t.done, what: t.text) {
                            changeTodos(shown: toggleTodo(todoText, line: t.line)) { try model.library.toggleTodo(path, line: t.line, text: t.text) }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.text).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary).textSelection(.enabled)
                            let detail = [t.owner.isEmpty ? nil : ownerLabel(t.owner, model.config.myName), t.due.isEmpty ? nil : "due \(t.due)"].compactMap { $0 }
                            if !detail.isEmpty { Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if !t.stamp.isEmpty { Chip(text: t.stamp) { jumpTo(t.stamp) } }
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.quaternary)
                    TextField("Add a to-do, then Return", text: $newTodo)
                        .textFieldStyle(.plain)
                        .help("Add an owner or due date with dashes: Send the deck - Jane - due Fri, Nov 6")
                        .onSubmit {
                            guard !newTodo.trimmed.isEmpty else { return }
                            let typed = typedTodo(newTodo)
                            changeTodos(shown: addTodo(todoText, typed)) { try model.library.addTodo(path, typed); return true }
                            newTodo = ""
                        }
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// The summary templates a meeting can be regenerated with: named, and with instructions.
    private var templates: [SummaryTemplate] {
        model.config.summaryTemplates.filter { model.config.summaryTemplate(named: $0.name) != nil }
    }

    private func regenerate(_ part: SummaryPart, template: SummaryTemplateChoice = .meetings) {
        // Save edits before asking for a replacement; a failed save must not discard pending text.
        flush()
        guard pending.isEmpty else { return }
        model.jobs.regenerate(part, path, template: template)
    }

    /// A meeting without its summary: it's being written now (after a save), or the model couldn't
    /// be reached and it can be written when it can.
    @ViewBuilder private var summaryLater: some View {
        if model.jobs.summarising.contains(path) {
            Notice(tone: .blue) {
                Text("Writing the summary…").fontWeight(.semibold)
                Text(model.downloads.modelDownloadStatus.map { "\($0). The summary is written as soon as it’s here; the transcript and your notes are already saved." }
                     ?? "The transcript and your notes are already saved.")
            }
        } else {
            let error = model.jobs.summaryErrors[path]
            Notice(tone: error == nil ? .grey : .red) {
                Text("No summary yet").fontWeight(.semibold)
                if let error {
                    ModelError(raw: error, prefix: "Couldn’t write it. ")
                } else {
                    Text("The transcript and your notes are saved. Oatcake can write the summary and to-dos from them now.")
                }
                HStack(spacing: 10) {
                    Button("Write summary") { model.jobs.writeSummary(path) }
                    // What stopped it is usually put right in Settings: the model, or its download.
                    if error != nil { SettingsPaneLink(pane: "models", title: "Open Settings").buttonStyle(.link) }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Transcript

    /// A line of the transcript as shown; one without a speaker is a plain paragraph.
    private struct Row {
        var speaker: String?
        var stamp = ""
        var text: String
    }

    /// The rows that have what's being looked for.
    private func matches(in rows: [Row]) -> [Int] {
        let wanted = query.trimmed
        guard !wanted.isEmpty else { return [] }
        return rows.indices.filter { rows[$0].text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func findBar(_ found: [Int]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(1, found) }
                .onChange(of: query) { match = 0 }
            Text(query.trimmed.isEmpty ? "" : found.isEmpty ? "Not found" : "\(min(match, found.count - 1) + 1) of \(found.count)")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Button { step(-1, found) } label: { Image(systemName: "chevron.up") }.disabled(found.isEmpty).help("Previous").accessibilityLabel("Previous match")
            Button { step(1, found) } label: { Image(systemName: "chevron.down") }.disabled(found.isEmpty).help("Next (Return)").accessibilityLabel("Next match")
            Button("Done") { endFind() }.help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .onKeyPress(.escape) {
            endFind()
            return .handled
        }
    }

    private func step(_ by: Int, _ found: [Int]) {
        guard !found.isEmpty else { return }
        match = (min(match, found.count - 1) + by + found.count) % found.count
    }

    private func endFind() {
        finding = false
        findFocused = false
        query = ""
        match = 0
    }

    /// The text with what's being looked for marked.
    private func marked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let wanted = query.trimmed
        guard finding, !wanted.isEmpty else { return out }
        var from = text.startIndex
        while let range = text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) {
                // The system's own find highlight, with the dark text it's made for: in a dark window
                // the usual white text on a see-through yellow couldn't be read.
                out[lower..<upper].backgroundColor = Color(nsColor: .findHighlightColor)
                out[lower..<upper].foregroundColor = .black
            }
            from = range.upperBound
        }
        return out
    }

    private func transcript(_ rows: [Row], current: Int?) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                // A long turn is several paragraphs: the ones after the first show only their time.
                let continued = i > 0 && row.speaker != nil && rows[i - 1].speaker == row.speaker
                HStack(alignment: .top, spacing: 10) {
                    if let speaker = row.speaker {
                        Avatar(name: speaker, size: 24).opacity(continued ? 0 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                if !continued { Text(speaker).fontWeight(.semibold) }
                                Text(row.stamp).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.callout)
                            Text(marked(row.text)).font(.system(size: 14 * scale)).lineSpacing(3).textSelection(.enabled)
                        }
                    } else {
                        Text(marked(row.text)).font(.system(size: 14 * scale)).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, continued ? 3 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == flash || i == current ? Color.orange.opacity(0.16) : .clear))
                .id(i)
            }
            if rows.isEmpty { Text("transcript.md is empty.").foregroundStyle(.secondary) }
        }
    }

    private func notes(_ files: [FileKey: String]) -> some View {
        let notes = parseNotes(files[.notes] ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Chip(text: n.stamp ?? "Prep", style: n.stamp == nil ? .prep : .normal)
                    Text(n.text).font(.system(size: 13 * scale)).textSelection(.enabled)
                }
            }
            if notes.isEmpty {
                Text(granola ? "No notes. Granola didn’t keep your notes when this meeting was imported." : "You didn’t take notes in this meeting.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Draft for Sharing…: what the draft is written from, and anything wanted for this one alone. Its
/// button says whether it replaces a draft that's there, so it asks once.
private struct DraftForSharingSheet: View {
    /// The meeting has a draft for sharing already, which the new one takes the place of.
    let replacing: Bool
    /// Whether to-dos are collected (Settings › General): while they're off, the sheet doesn't mention them.
    let todos: Bool
    let write: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var request = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Draft for Sharing").font(.headline)
            Text("Oatcake’s model writes this meeting’s \(todos ? "summary and to-dos" : "summary") again for other people to read, following your draft for sharing instructions in Settings › Summaries. It doesn’t read the transcript or your notes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("For this draft only (optional)")
                // Plain, with a border of its own: the rounded style draws one line whatever space is reserved.
                TextField("", text: $request, prompt: Text("Shorter, and leave out the budget"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
                    .accessibilityLabel("For this draft only")
            }
            if replacing {
                Text("This replaces the draft for sharing that’s there, including your edits to it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replacing ? "Replace Draft" : "Write Draft") {
                    write(request.trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

import OatcakeCore
import SwiftUI
import UserNotifications

/// The Settings window, in panes. Every change is saved as it's made; there's no Save button.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var devices: [InputDevice]?
    @ViewState private var jargon = ""
    @ViewState private var ignoredEvents = ""
    @ViewState private var calendarEditor: CalendarSettingsEdit?
    /// macOS says notifications are turned off for Oatcake: reminders and call notices can't show.
    @ViewState private var notificationsOff = false
    @AppStorage("settingsPane") private var pane = "general"

    var body: some View {
        TabView(selection: $pane) {
            Form { general }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            Form { calendar }.formStyle(.grouped).tabItem { Label("Calendars", systemImage: "calendar") }.tag("calendar")
            Form { PeopleSection() }.formStyle(.grouped).tabItem { Label("People", systemImage: "person.2") }.tag("people")
            Form { transcription; llmSection }.formStyle(.grouped).tabItem { Label("Models", systemImage: "cpu") }.tag("models")
            Form { jargonSection; outputSections }.formStyle(.grouped).tabItem { Label("Summaries", systemImage: "text.alignleft") }.tag("summaries")
            Form { storage; mcp }.formStyle(.grouped).tabItem { Label("Storage", systemImage: "folder") }.tag("storage")
            Form { UpdatesSection() }.formStyle(.grouped).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
        }
        .frame(width: 620, height: 600)
        .sheet(item: $calendarEditor) { editor in
            CalendarEditor(calendar: model.calendar, existing: editor.existing)
        }
        // Something that went wrong while this window is in front (a setting that couldn't be saved)
        // is said here too: the main window's own note is behind this one, or closed.
        .overlay(alignment: .bottom) {
            if let text = model.toastText, model.toastIsError { ToastView(text: text, isError: true) { model.dismissToast() } }
        }
        .task { devices = (try? await Recordings.listInputs()) ?? [] }
        // Looked at again whenever a pane is shown: it may have been changed in System Settings meanwhile.
        .task(id: pane) { notificationsOff = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied }
        .onAppear {
            // Speech to text was once a pane of its own, now part of Models.
            if pane == "transcription" { pane = "models" }
            jargon = model.config.jargon.joined(separator: ", ")
            ignoredEvents = model.config.ignoredEvents.joined(separator: ", ")
            // The Electron version's names for the two transcription choices read as the new ones.
            let key = SpeechModels.asrChoice(model.config.asrModel).key
            if key != model.config.asrModel { model.saveConfig(with(model.config) { $0.asrModel = key }) }
        }
    }

    @ViewBuilder private var general: some View {
        let config = model.config
        Section("You") {
            TextField(text: bind(\.myName), prompt: Text("Your name")) {
                Text("Your name")
                Text("Labels your microphone track in every transcript.")
            }
        }

        Section("App") {
            Toggle(isOn: bind(\.runInBackground)) {
                Text("Run in the background")
                Text("Keeps Oatcake in the menu bar, but not running in the Dock, after you close its last window. Turn this off to quit when the last window closes and any work has finished.")
            }
        }

        Section("Recording") {
            LabeledContent {
                MicPicker(devices: devices ?? []).frame(width: 270)
            } label: {
                Text("Microphone")
                if let devices {
                    let hint = micHint(config.mic, devices)
                    Text(hint.text).foregroundStyle(hint.color)
                }
            }
            Toggle(isOn: bind(\.liveTranscript)) {
                Text("Live transcript")
                Text("Shows what’s being said beside your notes during the call, transcribed on your Mac.")
            }
            Toggle(isOn: bind(\.liveVoices)) {
                Text("Name voices during the call")
                Text("Names the people Oatcake knows by voice in the live transcript, and lets you click a line to say who said it. Who’s who starts from the names you give. Turned off, a call uses about 180 MB less memory and a little less CPU.")
            }
            .disabled(!config.liveTranscript)
            Picker(selection: bind(\.afterCall)) {
                Text("Wait for me to check who’s who").tag(AfterCall.review)
                Text("Save with a summary").tag(AfterCall.saveWithSummary)
                Text("Save the transcript only").tag(AfterCall.saveTranscript)
            } label: {
                Text("After a call")
                Text(afterCallHint(config.afterCall))
            }
        }

        Section {
            Toggle(isOn: bind(\.callNotice)) {
                Text("Offer to record when a call starts")
                Text("A notification with a Start recording button when a calling app or browser starts using your microphone.")
            }
            if model.config.callNotice { notificationsHint }
            Toggle(isOn: bind(\.autoStop)) {
                Text("Stop recording when the call ends")
                Text("Once the calling app has let go of your microphone and the call audio has been quiet for 15 seconds, Oatcake says the call seems to have ended. It stops recording 30 seconds later, unless you choose Keep recording or the call comes back.")
            }
        } header: {
            Text("Calls")
        } footer: {
            Text("Oatcake notices a call by which apps have the microphone open. It doesn’t listen until you record.").settingsHint()
        }

        Section("To-dos") {
            Toggle(isOn: bind(\.todosEnabled)) {
                Text("Collect to-dos")
                Text("Each summary comes with the to-dos agreed in the call. Turned off, none are collected and the To-dos page is hidden; saved ones stay in each meeting’s todo.md.")
            }
        }
    }

    private func afterCallHint(_ choice: AfterCall) -> String {
        switch choice {
        case .review: "Each call waits under Needs review until you’ve named its voices and saved it."
        case .saveWithSummary: "Each call is saved once it’s processed, and summarised. Voices Oatcake is sure it recognises keep their names; the rest are “Voice 1”, “Voice 2”… until you name them from the meeting."
        case .saveTranscript: "Each call is saved once it’s processed, with no summary or to-dos. Voices Oatcake is sure it recognises keep their names; the rest are “Voice 1”, “Voice 2”… until you name them from the meeting."
        }
    }

    /// Other apps' MCP access to the Meetings folder. They start `Oatcake --mcp` themselves, so
    /// there's nothing here to start or stop: only whether it may read, and what to give an app.
    private var mcp: some View {
        Section {
            Toggle("Let other apps read my meetings", isOn: bind(\.mcpEnabled))
            if model.mcpOffNotSaved, !model.config.mcpEnabled {
                Text("Oatcake couldn’t save this, so apps you’ve added it to can still read your meetings.")
                    .settingsHint(.amber)
                Button("Retry Saving") { model.retrySavingMCPOff() }
            }
            if model.config.mcpEnabled {
                if model.config.mcpApprovedRoot == nil {
                    Text("Oatcake couldn’t check the Meetings folder, so apps can’t read it yet. Check it above, then turn this off and on again.")
                        .settingsHint(.amber)
                }
                Text("Add Oatcake to an app that supports MCP with this:").settingsHint()
                // All of it in view: it's short, and it's there to be selected and copied whole.
                Text(verbatim: MCPServer.configuration(executable: Bundle.main.executablePath ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("MCP configuration")
            }
        } header: {
            // What it does, in plain words: MCP is named in the setup shown once it's on.
            Text("Other apps")
        } footer: {
            Text("An app you add Oatcake to starts its reader itself, whether or not Oatcake is open, and can read your whole Meetings folder while this is on. An app that uses an online model may send what it reads to that service.")
                .settingsHint()
        }
    }

    @ViewBuilder private var storage: some View {
        Section {
            LabeledContent {
                Button("Choose…") { model.chooseMeetingsFolder() }
            } label: {
                Text("Meetings folder")
                Text(shortPath(model.config.outputDir)).font(.system(.caption, design: .monospaced)).help(model.config.outputDir)
            }
            Toggle(isOn: bind(\.keepAudio)) {
                Text("Keep call audio after saving")
                Text("When off, the audio is deleted once a meeting is saved. The transcript, notes and summary stay.")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Choosing another Meetings folder doesn’t move anything: meetings already in the old one stay where they are.").settingsHint()
        }
        Section("Import") {
            ImportRow(source: "Granola", hint: "Pick the .zip from Granola’s export. Each note becomes a meeting; ones already here are skipped.",
                      pick: model.library.importGranolaExport)
            ImportRow(source: "Quill", hint: "Pick the .zip from Quill’s backup. Each meeting becomes a meeting, with its recording; ones already here are skipped.",
                      pick: model.library.importQuillBackup)
        }
    }

    @ViewBuilder private var calendar: some View {
        Section {
            CalendarSettingsRows(calendar: model.calendar, editor: $calendarEditor)
        } header: {
            Text("Calendars")
        } footer: {
            Text("In Google Calendar, open Settings, pick a calendar under “Settings for my calendars”, then copy its “Secret address in iCal format” from Integrate calendar. Repeat for each calendar you want in Upcoming.")
                .settingsHint()
        }
        Section("Reminders") {
            Toggle(isOn: bind(\.callReminders)) {
                Text("Remind me before calls")
                Text("Before each call, a notification with a button that opens the call and starts recording, ready for notes.")
            }
            if model.config.callReminders {
                ReminderTimesRows(minutes: bind(\.reminderMinutes))
                notificationsHint
            }
            Toggle(isOn: bind(\.menuBarNextCall)) {
                Text("Show my next call in the menu bar")
                Text("The time until it starts, with what’s coming up in its menu.")
            }
        }
        // Typed as one comma-separated line, like Jargon; kept as a list.
        Section {
            TextField("Leave out", text: $ignoredEvents, prompt: Text("Focus time, Out of office"), axis: .vertical)
                .lineLimit(1...4)
                .labelsHidden()
                .onChange(of: ignoredEvents) {
                    let titles = commaList(ignoredEvents)
                    if titles != model.config.ignoredEvents { model.saveConfig(with(model.config) { $0.ignoredEvents = titles }) }
                }
        } header: {
            Text("Events that aren’t calls")
        } footer: {
            Text("Separated by commas. Events whose titles start with one of these, or have “Oatcake ignore” anywhere in them, are left out of Upcoming, the menu bar and reminders. Capitals don’t matter, and “Task” doesn’t leave out “Taskforce sync”.")
                .settingsHint()
        }
        // Ignored one at a time from Upcoming's right-click menu. Only shown once there are some.
        let ignored = withoutEnded(model.config.ignoredCalendarEvents, now: Date())
        if !ignored.isEmpty {
            Section {
                ForEach(ignored) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.series ? "This and following events" : parseISO(item.start).map { "\(shortWeekday($0)) \(hhmm($0))" } ?? "Once")
                                .settingsHint()
                        }
                        Spacer()
                        Button("Stop Ignoring") { model.stopIgnoring(item) }
                    }
                }
            } header: {
                Text("Ignored events")
            } footer: {
                Text("Right-click an event in Upcoming to ignore it. Only Oatcake leaves it out: it stays in your calendar. An event its organiser moves shows again, and so does the rest of a series changed with “this and following events”.")
                    .settingsHint()
            }
        }
    }

    @ViewBuilder private var transcription: some View {
        Section {
            Picker("Speech to text", selection: bind(\.asrModel)) {
                ForEach(SpeechModels.asr, id: \.key) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.title)
                        Text(choice.detail).settingsHint()
                    }
                    .tag(choice.key)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        } header: {
            Text("Speech to text")
        } footer: {
            Text("Runs on your Mac. Audio never leaves it for transcription.").settingsHint()
        }
    }

    /// Shown under a switch that works by notification, when macOS won't show Oatcake's.
    @ViewBuilder private var notificationsHint: some View {
        if notificationsOff {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Notifications are turned off for Oatcake in System Settings, so this can’t be shown.").settingsHint(.amber)
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        }
    }

    /// Typed as one comma-separated line; kept as a list.
    @ViewBuilder private var jargonSection: some View {
        Section {
            TextField("Jargon", text: $jargon, prompt: Text("Automattic, WooCommerce, Jetpack"), axis: .vertical)
                .lineLimit(2...5)
                .labelsHidden()
                .onChange(of: jargon) {
                    let terms = commaList(jargon)
                    if terms != model.config.jargon { model.saveConfig(with(model.config) { $0.jargon = terms }) }
                }
        } header: {
            Text("Jargon")
        } footer: {
            Text("Names, products and acronyms, separated by commas. Summaries, to-dos, name suggestions and answers spell them as written here. Transcripts keep what the speech model heard.")
                .settingsHint()
        }
    }

    private func bind<T>(_ path: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: path] }, set: { value in model.saveConfig(with(model.config) { $0[keyPath: path] = value }) })
    }

    private func bindLlm<T>(_ path: WritableKeyPath<LlmConfig, T>) -> Binding<T> {
        let llm: WritableKeyPath<Config, LlmConfig> = \.llm
        return bind(llm.appending(path: path))
    }

    /// "~/Documents/…/Meetings": long paths lose their middle; hover shows the full path.
    private func shortPath(_ full: String) -> String {
        let p = full.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
        return p.count <= 46 ? p : "\(p.prefix(20))…\(p.suffix(24))"
    }

    @ViewBuilder private var llmSection: some View {
        let llm = model.config.llm
        Section {
            Picker("Language model", selection: bindLlm(\.model)) {
                ForEach(LocalModels.all) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.title + (choice == LocalModels.recommended() ? " · recommended for this Mac" : ""))
                        Text(choice.detail).settingsHint()
                        if !LocalModels.fits(choice) {
                            Text("This Mac has \(Int(LocalModels.physicalMemory.rounded())) GB of memory, which is too little for it.").settingsHint(.amber)
                        }
                    }
                    .tag(choice.id)
                }
                VStack(alignment: .leading) {
                    Text("A model server of my own")
                    Text("Ollama, LM Studio or another server with the same chat API, on this Mac or your own network.").settingsHint()
                }
                .tag(LlmConfig.ownServer)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let chosen = LocalModels.find(llm.model) {
                ModelRow(chosen: chosen)
            } else {
                TextField(text: bindLlm(\.own.baseUrl), prompt: Text("e.g. http://localhost:11434/v1")) {
                    Text("Endpoint").font(.body)
                    if llm.own.baseUrl.trimmed.isEmpty {
                        Text("Required").font(.callout).foregroundStyle(Color.amber)
                    } else if !isLocalEndpoint(llm.own.baseUrl) {
                        Text("Has to be on this Mac or your network").font(.callout).foregroundStyle(Color.amber)
                    }
                }
                .font(.system(.body, design: .monospaced))
                TextField(text: bindLlm(\.own.model), prompt: Text("e.g. qwen3:14b")) {
                    Text("Model").font(.body)
                    if llm.own.model.trimmed.isEmpty { Text("Required").font(.callout).foregroundStyle(Color.amber) }
                }
                .font(.system(.body, design: .monospaced))
                // How much Oatcake sends at once. The server keeps its own setting: this only has to match it.
                TextField(value: bindLlm(\.own.context), format: .number.grouping(.never),
                          prompt: Text(String(LocalModels.nativeContext))) {
                    Text("Context").font(.body)
                    if let context = llm.own.context, context < LlmConfig.Own.minimumContext {
                        Text("Oatcake needs at least \(LlmConfig.Own.minimumContext.formatted()) tokens, and plans for that")
                            .font(.callout).foregroundStyle(Color.amber)
                    } else {
                        Text("Tokens your server is set to hold (Ollama’s num_ctx, llama.cpp’s -c). This tells Oatcake how much to send at once; it doesn’t change the server. Empty: \(LocalModels.nativeContext.formatted()).")
                            .settingsHint()
                    }
                }
                .font(.system(.body, design: .monospaced))
                Picker(selection: bindLlm(\.own.reasoningControl)) {
                    Text("Leave it to the server").tag(nil as LlmConfig.ReasoningControl?)
                    Text("Ollama (reasoning_effort)").tag(Optional(LlmConfig.ReasoningControl.ollama))
                    Text("llama.cpp (enable_thinking)").tag(Optional(LlmConfig.ReasoningControl.llamaCpp))
                } label: {
                    Text("Reasoning switch")
                    Text(llm.own.reasoningControl == nil
                         ? "The server decides whether its model reasons first. Choose the switch it takes to use the Reasoning switches in Settings › Summaries."
                         : "Each task’s Reasoning switch in Settings › Summaries is sent this way. A model that can’t turn reasoning off keeps its least.")
                        .settingsHint()
                }
            }
            TestRow(missing: testBlocker(llm)).id(llm.model)
        } header: {
            Text("Language model")
        } footer: {
            Text("Writes summaries, to-dos and drafts for sharing, suggests names and answers questions. It runs on this Mac; nothing from your calls is sent anywhere.")
                .settingsHint()
        }
    }

    /// Why Test can't be pressed yet, if it can't.
    private func testBlocker(_ llm: LlmConfig) -> String? {
        let _ = model.downloads.modelsVersion
        if let chosen = LocalModels.find(llm.model) { return LocalModels.isDownloaded(chosen) ? nil : "Download the model first." }
        if llm.own.baseUrl.trimmed.isEmpty || llm.own.model.trimmed.isEmpty { return "Fill in the endpoint and model first." }
        return isLocalEndpoint(llm.own.baseUrl) ? nil : "The endpoint has to be on this Mac or your own network."
    }

    /**
     * One section for each thing the model writes: its instructions (Oatcake's own until you change
     * them) beside its reasoning switch, so everything about one output is in one place.
     */
    @ViewBuilder private var outputSections: some View {
        Section {
            InstructionsRow(title: "Summary instructions", setting: \.summaryInstructions, standard: defaultSummaryInstructions,
                            applies: "Used for summaries written from now on.")
            reasoningToggle(\.summary, detail: "Slower, but in Oatcake’s tests decisions went to the right person more reliably.")
        } header: {
            Text("Summary")
        } footer: {
            Text("What the model writes once it has read the transcript. Change the headings, the level of detail or the language.").settingsHint()
        }
        TemplatesSections()
        if model.config.todosEnabled {
            Section {
                InstructionsRow(title: "To-do instructions", setting: \.todoInstructions, standard: defaultTodoInstructions,
                                applies: "Used for to-dos collected from now on.")
                reasoningToggle(\.todos, detail: "Slower, and in Oatcake’s tests to-dos lost detail, so it starts off.")
            } header: {
                Text("To-dos")
            } footer: {
                Text("What counts as a to-do. Each still comes with its owner, due date and time in the call.").settingsHint()
            }
        }
        Section {
            InstructionsRow(title: "Draft for sharing instructions", setting: \.sharingInstructions, standard: defaultSharingInstructions,
                            applies: "Used for drafts written from now on.")
            reasoningToggle(\.sharing, detail: "Slower. It starts on, as for summaries.")
        } header: {
            Text("Draft for sharing")
        } footer: {
            Text("Draft for Sharing… in a meeting rewrites its \(model.config.todosEnabled ? "summary and to-dos" : "summary") for other people. It doesn’t read the transcript or your notes.").settingsHint()
        }
        Section {
            reasoningToggle(\.names, title: "Name suggestions", detail: "Slower, but in Oatcake’s tests names were made up less often.")
            reasoningToggle(\.ask, title: "Ask", detail: "Slower, but in Oatcake’s tests answers kept to the question more.")
        } header: {
            Text("Reasoning for name suggestions and Ask")
        }
    }

    /**
     * Whether the model thinks a task through before it replies. Oatcake's own models are always told;
     * a server of yours only once you've said which switch it takes (Settings › Models). Until then it
     * decides for itself, so the switch is shown but can't be changed.
     */
    private func reasoningToggle(_ task: WritableKeyPath<LlmConfig.Reasoning, Bool>, title: String = "Reasoning", detail: String) -> some View {
        let undecided = LocalModels.find(model.config.llm.model) == nil && model.config.llm.own.reasoningControl == nil
        let reasoning: WritableKeyPath<LlmConfig, LlmConfig.Reasoning> = \.reasoning
        return Toggle(isOn: bindLlm(reasoning.appending(path: task))) {
            Text(title)
            Text(undecided ? "A model server of your own decides this for itself, until you choose its reasoning switch in Settings › Models."
                 : "The model thinks it through before replying. \(detail)")
        }
        .disabled(undecided)
    }
}

/**
 * One of the model's sets of instructions, as a row saying whose they are. Edit… opens them below it,
 * saved as they're typed; Restore Default… brings Oatcake's own back.
 */
private struct InstructionsRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let setting: WritableKeyPath<Config, String>
    /// Oatcake's own wording.
    let standard: String
    let applies: String
    @ViewState private var text = ""
    @ViewState private var editing = false
    @ViewState private var restoring = false

    var body: some View {
        LabeledContent {
            HStack {
                // It only does anything when the instructions have been changed, and then it asks: they're yours.
                if editing {
                    Button("Restore Default…") { restoring = true }.disabled(text.trimmed == standard.trimmed)
                        .alert("Restore Oatcake’s own \(title.lowercased())?", isPresented: $restoring) {
                            Button("Restore Default", role: .destructive) { text = standard }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("The instructions you’ve written here are replaced, and can’t be brought back.")
                        }
                }
                Button(editing ? "Done" : "Edit…") { editing.toggle() }
                    .accessibilityLabel(editing ? "Done editing \(title.lowercased())" : "Edit \(title.lowercased())")
            }
        } label: {
            Text(model.config[keyPath: setting].trimmed.isEmpty ? "Oatcake’s own instructions" : "Your instructions")
            Text(applies)
        }
        .onAppear {
            let custom = model.config[keyPath: setting].trimmed
            text = custom.isEmpty ? standard : custom
        }
        if editing {
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(title)
                .onChange(of: text) {
                    // Oatcake's own wording is kept as "none of your own", so a later improvement to it reaches you.
                    let custom = text.trimmed == standard.trimmed ? "" : text
                    if custom != model.config[keyPath: setting] { model.saveConfig(with(model.config) { $0[keyPath: setting] = custom }) }
                }
        }
    }

    init(title: String, setting: WritableKeyPath<Config, String>, standard: String, applies: String) {
        self.title = title
        self.setting = setting
        self.standard = standard
        self.applies = applies
    }
}

/**
 * Summary templates: other summary instructions, each with a name, for the meetings that need a
 * different summary. One is picked for a meeting from its Regenerate menu, and kept for it.
 */
private struct TemplatesSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                Button("Add Template") { add() }
            } label: {
                Text(model.config.summaryTemplates.isEmpty ? "None yet" : model.config.summaryTemplates.map(\.name).joined(separator: ", "))
                Text("Pick one for a meeting from its ⋯ menu › Regenerate Summary.")
            }
        } header: {
            Text("Summary templates")
        } footer: {
            Text("Other summary instructions, each with a name: for a one-to-one you lead, say. A meeting keeps the template you regenerate it with; the rest use the summary instructions.")
                .settingsHint()
        }
        ForEach(model.config.summaryTemplates, id: \.name) { template in
            TemplateSection(template: template)
        }
    }

    /// A new one starts as a copy of the summary instructions, named "New template" (or "New template 2"…).
    private func add() {
        var name = "New template"
        var number = 2
        while model.config.summaryTemplates.contains(where: { $0.name.trimmed.lowercased() == name.lowercased() }) {
            name = "New template \(number)"
            number += 1
        }
        model.saveConfig(with(model.config) { $0.summaryTemplates.append(SummaryTemplate(name: name, instructions: $0.summaryTask)) })
    }
}

/// One summary template, to rename, edit or delete. Its instructions are saved as they're typed; its
/// name when you press Return or leave the field, or when the field goes (another pane, or Settings
/// closed), if no other template has it. Not as it's typed: the section is keyed by the name, so
/// saving each keystroke would remake the field under the cursor.
private struct TemplateSection: View {
    @Environment(AppModel.self) private var model
    /// As saved.
    let template: SummaryTemplate
    @ViewState private var name = ""
    @ViewState private var text = ""
    @ViewState private var nameProblem: String?
    @ViewState private var deleting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section {
            TextField("Name", text: $name)
                .focused($nameFocused)
                .onSubmit(saveName)
                .onChange(of: nameFocused) { if !nameFocused { saveName() } }
                .onDisappear(perform: saveName)
            if let nameProblem {
                Text(nameProblem).settingsHint(.red)
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Instructions for \(template.name)")
                .onChange(of: text) { change { $0.instructions = text } }
            LabeledContent {
                Button("Delete…") { deleting = true }
                    .alert("Delete the “\(template.name)” template?", isPresented: $deleting) {
                        Button("Delete", role: .destructive) {
                            model.saveConfig(with(model.config) { $0.summaryTemplates.removeAll { $0.name == template.name } })
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Summaries already written with it stay as they are. Those meetings are summarised with the summary instructions from now on, or with a template you give this name again.")
                    }
            } label: {
                Text(text.trimmed.isEmpty ? "Without instructions, meetings use the summary instructions" : "Used for the meetings you regenerate with it")
            }
        } header: {
            Text(template.name)
        }
        .onAppear {
            name = template.name
            text = template.instructions
        }
    }

    private func change(_ edit: (inout SummaryTemplate) -> Void) {
        var config = model.config
        guard let i = config.summaryTemplates.firstIndex(where: { $0.name == template.name }) else { return }
        edit(&config.summaryTemplates[i])
        if config != model.config { model.saveConfig(config) }
    }

    private func saveName() {
        let clean = name.trimmed
        guard clean != template.name else {
            nameProblem = nil
            return
        }
        if clean.isEmpty {
            nameProblem = "A template needs a name."
        } else if model.config.summaryTemplates.contains(where: { $0.name != template.name && $0.name.trimmed.lowercased() == clean.lowercased() }) {
            nameProblem = "There’s a template called “\(clean)” already."
        } else {
            nameProblem = nil
            change { $0.name = clean }
            return
        }
        name = template.name
    }
}

func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}

extension Text {
    func settingsHint(_ color: Color = .secondary) -> some View {
        font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings › Test: one short request to the chosen model, with the result underneath.
private struct TestRow: View {
    @Environment(AppModel.self) private var model
    let missing: String?
    @ViewState private var running = false
    @ViewState private var result: (ok: Bool, detail: String)?

    var body: some View {
        LabeledContent {
            Button(running ? "Testing…" : "Test") { Task { await test() } }.disabled(running || missing != nil)
        } label: {
            Text("Check it works")
            Text(missing ?? (running ? "Asking the model for a one-word reply…" : result?.detail ?? "Sends one short request with these settings."))
                .foregroundStyle(result?.ok == false && missing == nil ? Color.red : Color.secondary)
        }
    }

    private func test() async {
        running = true
        let started = Date()
        let llm = model.config.llm
        do {
            let check = try await withThrowingTaskGroup(of: ModelCheck.self) { group in
                group.addTask { try await checkModel(llm) }
                group.addTask {
                    try await Task.sleep(for: .seconds(120))
                    throw OatcakeError("No reply after two minutes")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let time = String(format: "%.1f", Date().timeIntervalSince(started))
            switch check {
            case .replied(let reply):
                result = (true, "Working: replied “\(reply.trimmed.prefix(40))” in \(time) s.")
            case .stillReasoning:
                result = (true, "Working: the model answered in \(time) s, but was still reasoning when this check stopped it. Summaries and other tasks give it far more room.")
            }
        } catch {
            result = (false, String(explainModelError(error.localizedDescription).prefix(300)))
        }
        running = false
    }
}

/// Settings › Models: whether the chosen model is on this Mac, with its download or removal.
private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let chosen: LocalModel
    @ViewState private var removing = false

    var body: some View {
        let _ = model.downloads.modelsVersion
        if let fraction = model.downloads.modelDownloads[chosen.id] {
            LabeledContent {
                Button("Stop") { model.downloads.stopModelDownload(chosen) }
            } label: {
                Text("Downloading \(chosen.title)")
                ProgressView(value: fraction).accessibilityLabel("Download progress")
                Text("\(Int(fraction * 100))% of \(chosen.downloadSize). It carries on from here if it’s stopped.")
            }
        } else if LocalModels.isDownloaded(chosen) {
            LabeledContent {
                Button("Remove…") { removing = true }
            } label: {
                Text("\(chosen.title) is on this Mac")
                Text("\(chosen.downloadSize), in Oatcake’s own folder.")
            }
            .alert("Remove \(chosen.title)?", isPresented: $removing) {
                Button("Remove", role: .destructive) { model.downloads.removeModel(chosen) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Frees \(chosen.downloadSize). It’s downloaded again the next time it’s needed.")
            }
        } else {
            let error = model.downloads.modelDownloadErrors[chosen.id]
            LabeledContent {
                HStack {
                    // A download that was stopped, or failed, leaves what it had fetched: gigabytes that only this removes.
                    if LocalModels.hasPartialDownload(chosen) {
                        Button("Remove Partial Download") { model.downloads.removeModel(chosen) }
                            .help("Deletes the part of \(chosen.title) that has been downloaded so far")
                    }
                    Button(error == nil ? "Download Now" : "Try Again") { model.downloads.downloadModel(chosen) }
                }
            } label: {
                Text("\(chosen.title) isn’t downloaded yet")
                Text(error ?? "\(chosen.downloadSize), from Hugging Face. It downloads by itself during your first call, or when it’s first needed.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
        }
    }
}

/// Settings › Storage › Import from Granola or Quill: the export's meetings go into a folder named after it.
private struct ImportRow: View {
    @Environment(AppModel.self) private var model
    let source: String
    let hint: String
    let pick: (@escaping ImportProgress) async -> Void
    @ViewState private var running = false
    /// Meetings handled and how many there are: set once a file is picked, 0 of 0 until the export has been read.
    @ViewState private var progress: (done: Int, total: Int)?

    var body: some View {
        LabeledContent {
            // One import at a time: the model knows of one that this row, if it was made afresh since, doesn't.
            Button(running || model.library.importing == source ? "Importing…" : "Import…") { Task { await run() } }
                .disabled(running || model.library.importing != nil)
        } label: {
            Text("Import from \(source)")
            if running, let progress, progress.total == 0 {
                ProgressView { Text("Reading the export…").foregroundStyle(.secondary) }.progressViewStyle(.linear)
            } else if running, let progress {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text("Importing \(progress.done) of \(progress.total) meetings…").foregroundStyle(.secondary)
                }
            } else if model.library.importing == source {
                // Settings was closed and opened again while it ran: it's still going, without the count.
                ProgressView { Text("Importing…").foregroundStyle(.secondary) }.progressViewStyle(.linear)
            } else {
                // What the last import did is the app's to remember, so it's here whenever Settings is opened.
                let outcome = model.library.importOutcomes[source]
                Text(outcome?.text ?? hint)
                    .foregroundStyle(outcome?.failed == true ? Color.red : Color.secondary)
            }
        }
    }

    private func run() async {
        running = true
        defer { running = false; progress = nil }
        // On the main queue, in order, as the import reports from its background task.
        await pick { done, total in DispatchQueue.main.async { progress = (done, total) } }
    }
}

/// The palette, to choose someone's colour from: it's theirs on every screen from then on.
private struct ColorChoice: View {
    let name: String
    let done: () -> Void

    var body: some View {
        let chosen = chosenColor(name)
        let palette = SwatchColour.allCases
        ColourSwatchPopover(title: "\(name)’s colour", selected: chosen.map { palette[$0] }, choose: { colour in
            chooseColor(palette.firstIndex(of: colour), for: name)
            done()
        }, reset: chosen == nil ? nil : {
            chooseColor(nil, for: name)
            done()
        })
    }
}

/// Settings › People: the voices Oatcake recognises, to rename or forget.
private struct PeopleSection: View {
    @ViewState private var voices: [KnownVoice] = []
    @ViewState private var renaming: KnownVoice?
    @ViewState private var forgetting: KnownVoice?
    /// Who's being merged, and into whom: asked first, as the two can't be told apart again.
    @ViewState private var merging: (voice: KnownVoice, into: KnownVoice, dropsOldest: Bool)?
    /// Whose colour is being chosen.
    @ViewState private var coloring: String?
    @ViewState private var draft = ""
    @ViewState private var error = ""

    var body: some View {
        Section {
            if voices.isEmpty {
                Text("Nobody yet. Names you confirm in Who’s who are remembered here.").settingsHint()
            }
            ForEach(voices) { voice in
                LabeledContent {
                    HStack {
                        Button { coloring = voice.name } label: { Avatar(name: voice.name, size: 22) }
                            .buttonStyle(.plain)
                            .help("Choose \(voice.name)’s colour")
                            .accessibilityLabel("\(voice.name)’s colour")
                            .popover(isPresented: Binding(get: { coloring == voice.name }, set: { if !$0 { coloring = nil } }), arrowEdge: .bottom) {
                                ColorChoice(name: voice.name) { coloring = nil }
                            }
                        Button("Rename…") {
                            draft = voice.name
                            renaming = voice
                        }
                        if voices.count > 1 {
                            Menu("Merge Into") {
                                ForEach(voices.filter { $0.name != voice.name }) { other in
                                    Button(other.name) {
                                        merging = (voice, other, mergedFingerprints(voice.name, into: other.name) > maxSamplesPerPerson)
                                    }
                                }
                            }
                            .fixedSize()
                            .help("Make \(voice.name) and someone else here one person, under the name you pick")
                        }
                        Button("Forget…") { forgetting = voice }
                    }
                } label: {
                    Text(voice.name)
                    Text(detail(voice))
                }
            }
            if !error.isEmpty { Text(error).settingsHint(.red) }
        } header: {
            Text("People")
        } footer: {
            Text("Oatcake recognises these voices on calls. Click someone’s avatar to choose their colour. Renaming changes the name it uses from now on; meetings already saved keep the name they were saved with. Merge Into makes two people one, under the name you pick.")
                .settingsHint()
        }
        .onAppear(perform: load)
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") {
                if let voice = renaming {
                    change {
                        try renameVoice(voice.name, to: draft)
                        carryChosenColor(from: voice.name, to: draft.trimmed)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let voice = renaming, draft.trimmed != voice.name, voices.contains(where: { $0.name == draft.trimmed }) {
                Text("\(draft.trimmed) is already here: the two become one person.")
            }
        }
        .alert(merging.map { "Merge \($0.voice.name) into \($0.into.name)?" } ?? "", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            Button("Merge", role: .destructive) {
                if let m = merging {
                    change {
                        try mergeVoice(m.voice.name, into: m.into.name)
                        carryChosenColor(from: m.voice.name, to: m.into.name)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let m = merging {
                Text("Oatcake recognises both voices as \(m.into.name) from now on, and \(m.voice.name) is no longer listed. Meetings already saved keep the names they have."
                     + (m.dropsOldest ? " Oatcake keeps \(maxSamplesPerPerson) fingerprints for one person, so the oldest of theirs go." : ""))
            }
        }
        .alert("Forget \(forgetting?.name ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let voice = forgetting { change { try forgetVoice(voice.name) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Oatcake won’t recognise their voice or suggest their name any more. Meetings already saved aren’t changed.")
        }
    }

    private func load() { voices = knownVoices() }

    private func change(_ work: () throws -> Void) {
        do {
            try work()
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
        load()
    }

    private func detail(_ voice: KnownVoice) -> String {
        if voice.calls == 0 { return "Recognised again after the next call you save with them" }
        let calls = "From \(voice.calls) call\(voice.calls == 1 ? "" : "s")"
        return voice.lastSaved.map { "\(calls) · last \(shortDate($0))" } ?? calls
    }
}

/// Settings › Updates: this version, Check Now, and the newer release when there is one.
private struct UpdatesSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var copied = false

    var body: some View {
        let u = model.updater
        Section("Updates") {
            LabeledContent {
                Button("Check Now") { Task { await u.check() } }.disabled(u.checking || u.installing != nil)
            } label: {
                Text("Oatcake \(u.current)")
                Text(u.error ?? status(u)).foregroundStyle(u.error != nil ? Color.red : Color.secondary)
            }
            if let available = u.available {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's new in \(available.version)")
                    if !available.notes.isEmpty {
                        Text(available.notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let blocked = u.blocked {
                        Text(blocked).font(.callout).foregroundStyle(Color.amber)
                        if let command = u.command {
                            HStack {
                                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(Color.fill))
                                Button(copied ? "Copied" : "Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                    copied = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        copied = false
                                    }
                                }
                            }
                        }
                    } else {
                        HStack {
                            Button(u.installing ?? "Install and Relaunch") { Task { await u.install() } }
                                .buttonStyle(.borderedProminent).disabled(u.installing != nil)
                            Text("\(Int((Double(available.size) / 1e6).rounded())) MB download. Oatcake quits and reopens.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Toggle(isOn: Binding(get: { model.config.updateCheck }, set: { v in model.saveConfig(with(model.config) { $0.updateCheck = v }) })) {
                Text("Check for updates automatically")
                Text("Once a day. Nothing is installed until you choose to.")
            }
        }
    }

    private func status(_ u: Updater) -> String {
        if u.checking { return "Checking…" }
        if let available = u.available { return "Oatcake \(available.version) is available." }
        if let checked = u.checkedAt { return "Up to date · checked at \(hhmm(checked))" }
        return "Not checked yet."
    }
}

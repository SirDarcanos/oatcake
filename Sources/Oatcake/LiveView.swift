import OatcakeCore
import SwiftUI

/// The call in progress: one note per line, each stamped with the time you started typing it.
///
/// Its parts are views of their own, each reading only what it shows: the recorder's status changes
/// twice a second, the notes with every key, and the transcript with every line.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    @ViewState private var showTranscript = UserDefaults.standard.object(forKey: "liveTranscriptShown") as? Bool ?? true
    /// People Oatcake knows by voice, to say who said a line.
    @ViewState private var knownVoices: [String] = []
    @ViewState private var paneWidth: CGFloat = 900

    private var status: RecorderStatus { model.recording.status }
    private var started: Bool { model.recording.started }
    private var elapsed: Double { status.elapsed ?? 0 }
    private var lines: [LiveLine] { model.recording.liveNotes[rec.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(pathAbove(rec.folder ?? "", rec.title)).foregroundStyle(.secondary)
                    PageTitle(text: rec.title).padding(.top, 4)
                    // Recording often starts before joining: the event's call link stays to hand.
                    if let link = model.recording.liveCallLink {
                        Button { NSWorkspace.shared.open(link) } label: { Label("Join the call", systemImage: "video") }
                            .help("Opens \(callApp(link.absoluteString) ?? "the call")")
                            .padding(.top, 10)
                    }
                    notices
                    LiveNotes(rec: rec).padding(.top, 24)
                    Text("One point per line. Each is stamped with the time you started typing it, and you can go back and edit any line.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 14)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if showTranscript && model.config.liveTranscript {
                Divider()
                LiveTranscriptPane(rec: rec, knownVoices: knownVoices).frame(width: sidePanelWidth(in: paneWidth))
            }
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            Divider()
            LiveBar()
        }
        .toolbar { toolbar }
        .onDisappear { model.recording.saveLiveNotes(rec.id) }
        .task { knownVoices = knownPeople() }
    }

    // MARK: Header

    /// The recording's state, then what can be done to it.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 8) {
                if started {
                    RecDot()
                    Text("Recording").foregroundStyle(.red).fontWeight(.semibold)
                    Text(clock(elapsed)).foregroundStyle(.red).monospacedDigit()
                } else {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                    Text(model.recording.recorderFailure != nil ? "Couldn’t record" : status.state == .starting ? "Starting…" : "Recording stopped").foregroundStyle(.secondary)
                }
            }
            .toolbarStatusPadding()
        }
        .withoutCapsule()
        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
        if model.config.liveTranscript {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding(get: { showTranscript }, set: { showTranscript = $0; UserDefaults.standard.set($0, forKey: "liveTranscriptShown") })) {
                    Text("Transcript")
                }
                .toggleStyle(.button)
                .help("Show or hide the live transcript")
            }
        }
        ToolbarItem(placement: .automatic) {
            // Nothing has been recorded until audio arrives, so until then it's Cancel, not Stop. A
            // recorder that never started has nothing to stop either: Close throws the recording away.
            if model.recording.recorderFailure != nil {
                Button("Close") { model.recording.cancelRecording(hasNotes: lines.contains { !$0.text.trimmed.isEmpty }) }
                    .help("Close this recording: nothing was recorded")
            } else if status.state == .starting {
                Button("Cancel") { model.recording.cancelRecording(hasNotes: lines.contains { !$0.text.trimmed.isEmpty }) }
                    .help("Cancel this recording")
            } else {
                Button { model.recording.confirmStop() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .help("Stop recording")
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if status.state == .starting && model.recording.recorderFailure == nil && Date().timeIntervalSince(rec.startedAt) > 6 {
            Notice(tone: .amber) {
                Text("The recorder hasn’t started yet").fontWeight(.semibold)
                Text("If macOS is asking whether Oatcake can use the microphone or record system audio, click Allow.")
            }
            .padding(.top, 16)
        }
        if let failure = model.recording.recorderFailure {
            Notice(tone: .red) {
                Text("This call isn’t being recorded").fontWeight(.semibold)
                Text(failure)
            }
            .padding(.top, 16)
        } else if status.state == .error {
            Notice(tone: .red) { Text(status.error ?? "The recorder stopped.") }.padding(.top, 16)
        }
        if let error = model.recording.liveNotesError {
            Notice(tone: .red) { Text(error) }.padding(.top, 16)
        }
        // The recording is about to stop by itself (Settings › General): say so, with the way to stop it stopping.
        if let stoppingAt = model.recording.stoppingAt {
            Notice(tone: .amber) {
                Text("The call seems to have ended").fontWeight(.semibold)
                Text("Recording stops in \(max(0, Int(stoppingAt.timeIntervalSinceNow.rounded(.up)))) seconds.")
                Button("Keep recording") { model.recording.keepRecording() }.padding(.top, 4)
            }
            .padding(.top, 16)
        }
        // The language model starts downloading with the first call, to be there when it ends.
        if let downloading = model.downloads.modelDownloadStatus {
            HStack(spacing: 6) {
                Text("\(downloading). It writes the summary once the call is over.")
                SettingsLink { Text("Settings") }.buttonStyle(.link)
                    .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("models", forKey: "settingsPane") })
            }
            .font(.callout).foregroundStyle(.secondary).padding(.top, 14)
        }
        let now = Date()
        if let since = model.recording.micQuietSince, now.timeIntervalSince(since) >= 30 {
            Notice(tone: .amber) {
                Text("Your microphone has been silent for \(Int(now.timeIntervalSince(since))) seconds").fontWeight(.semibold)
                Text("Check it isn’t muted, or switch to another microphone using the button below.")
            }
            .padding(.top, 16)
        }
        if let since = model.recording.callQuietSince, now.timeIntervalSince(since) >= 30 {
            Notice(tone: .amber) {
                Text("No call audio for \(Int(now.timeIntervalSince(since))) seconds").fontWeight(.semibold)
                Text("If people are talking, allow Oatcake in System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
            .padding(.top, 16)
        }
    }
}

// MARK: Live transcript

/// What's been said so far, a moment after each pause. Your microphone is you. A line from the call
/// side has the name of whoever it sounds like, when voices are named (Settings › General), and
/// otherwise an obviously made-up name of its own until the call is over and the voices are told apart.
private struct LiveTranscriptPane: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    let knownVoices: [String]

    var body: some View {
        let lines = model.recording.liveShown
        let myName = model.config.myName.isEmpty ? "You" : model.config.myName
        // Names as text, in the shade that reads against the window (the avatar's own is too close to it).
        let colors = provisionalNameColors([myName] + Set(lines.compactMap(\.speaker)).sorted())
        let mine = colors[myName] ?? .primary
        let namesVoices = model.config.liveVoices
        let state = model.recording.liveState
        let stopped: String? = if case .stopped(let why) = state { "The live transcript stopped: \(why)" } else { nil }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(text: "Live transcript")
                        Spacer()
                        // Once there's a line, and so a name, to click.
                        if !lines.isEmpty {
                            Text(namesVoices ? "Click a name to say who it is" : "Names come after the call").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if lines.isEmpty && stopped == nil {
                        Text(waiting(state))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if line.track == .mic {
                                    Text(myName).fontWeight(.semibold).foregroundStyle(mine)
                                } else if namesVoices {
                                    speaker(line, myName: myName, color: line.speaker.flatMap { colors[$0] })
                                } else {
                                    Text(callPlaceholder(for: rec.id, lineAt: line.start)).fontWeight(.semibold).foregroundStyle(.secondary)
                                }
                                Text(clock(line.start)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.caption)
                            Text(line.text).font(.callout).textSelection(.enabled)
                        }
                    }
                    if let stopped { Text(stopped).font(.callout).foregroundStyle(.red) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Who said a line from the call side, as a menu to say who it was: people Oatcake knows by voice,
    /// and the people on the calendar invite. Oatcake follows that voice for the rest of the call, and
    /// Who's who starts from it after the call.
    private func speaker(_ line: LiveTranscriptLine, myName: String, color: Color?) -> some View {
        let given = liveName(for: line, in: model.recording.liveNames)?.name
        let invited = (rec.attendees ?? []).filter { $0 != myName && !knownVoices.contains($0) }
        return Menu {
            if !knownVoices.isEmpty {
                Section("Known voices") { ForEach(knownVoices, id: \.self) { choice($0, for: line, given: given) } }
            }
            if !invited.isEmpty {
                Section("On the invite") { ForEach(invited, id: \.self) { choice($0, for: line, given: given) } }
            }
            if knownVoices.isEmpty && invited.isEmpty {
                Text("Nobody to choose yet: people appear here once Oatcake knows their voice, or when they’re on the calendar invite.")
            }
            if given != nil {
                Divider()
                Button("Take back “\(given ?? "")”") { model.recording.nameLiveLine(line, as: nil) }
            }
        } label: {
            Text(line.speaker ?? callPlaceholder(for: rec.id, lineAt: line.start)).font(.caption.weight(.semibold))
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
        // Drawn as the name it is, like yours beside it: a borderless menu would set it in its own font.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who said this?")
    }

    @ViewBuilder private func choice(_ name: String, for line: LiveTranscriptLine, given: String?) -> some View {
        Button { model.recording.nameLiveLine(line, as: name) } label: {
            if given == name { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
    }

    /// What the transcript pane says before there are any lines to show.
    private func waiting(_ state: LiveTranscriptState) -> String {
        switch state {
        case .idle, .at(.listening): "Listening. What’s said appears here a moment after each pause."
        case .starting: "Starting…"
        case .at(let stage): "\(stage.title)…"
        case .stopped: ""
        }
    }
}

// MARK: Notes

/// The notes typed during the call, one point per line.
private struct LiveNotes: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    @FocusState private var focused: UUID?
    @AppStorage(TextScale.key) private var textScale = 1.0

    private var lines: [LiveLine] { model.recording.liveNotes[rec.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in noteRow(line) }
        }
        .onAppear(perform: loadNotes)
    }

    /// What's saved (prep notes, or notes from before the window reopened), then a blank line.
    private func loadNotes() {
        if model.recording.liveNotes[rec.id] == nil {
            let saved = Recordings.loadNotes(rec.id).map { LiveLine(at: $0.at, prep: $0.at == nil, text: $0.text) }
            model.recording.liveNotes[rec.id] = saved + [LiveLine(at: nil, prep: false, text: "")]
        }
        focused = lines.last?.id
    }

    private func update(_ next: [LiveLine], focus: UUID? = nil) {
        model.recording.liveNotes[rec.id] = next
        model.recording.liveNotesChanged(rec.id)
        if let focus { DispatchQueue.main.async { focused = focus } }
    }

    private func noteRow(_ line: LiveLine) -> some View {
        let index = lines.firstIndex { $0.id == line.id } ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                // A line not begun yet shows the call's clock, which ticks: only its chip is drawn again for it.
                if line.at == nil && !line.prep {
                    PendingChip()
                } else {
                    Chip(text: line.prep ? "Prep" : clock(line.at ?? 0), style: line.prep ? .prep : .normal)
                }
            }
            .frame(width: 58, alignment: .leading)
            TextField(index == lines.count - 1 && line.text.isEmpty ? "Type a point, then Return" : "", text: Binding(
                get: { line.text },
                set: { text in
                    // Before audio arrives the clock hasn't started, so a line begun then is stamped 00:00:
                    // it's a note from the call, not prep. Only notes written on New recording are prep.
                    let started = model.recording.started, elapsed = model.recording.status.elapsed ?? 0
                    update(lines.map { l in
                        guard l.id == line.id else { return l }
                        var l = l
                        l.text = text
                        l.at = l.prep || text.isEmpty ? nil : l.at ?? (started ? elapsed.rounded(.down) : 0)
                        return l
                    })
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 14 * TextScale.clamped(textScale)))
                .focused($focused, equals: line.id)
                .onSubmit { returnPressed(on: line) }
                .onKeyPress(.upArrow) { move(from: line, by: -1) }
                .onKeyPress(.downArrow) { move(from: line, by: 1) }
                .onKeyPress(.delete) {
                    guard line.text.isEmpty, lines.count > 1 else { return .ignored }
                    let i = lines.firstIndex { $0.id == line.id } ?? 0
                    let next = lines.indices.contains(i - 1) ? lines[i - 1].id : lines[min(i + 1, lines.count - 1)].id
                    update(lines.filter { $0.id != line.id }, focus: next)
                    return .handled
                }
        }
    }

    private func returnPressed(on line: LiveLine) {
        guard !line.text.trimmed.isEmpty, let i = lines.firstIndex(where: { $0.id == line.id }) else {
            focused = line.id
            return
        }
        if lines.indices.contains(i + 1), lines[i + 1].text.isEmpty {
            focused = lines[i + 1].id
            return
        }
        let added = LiveLine(at: nil, prep: false, text: "")
        var next = lines
        next.insert(added, at: i + 1)
        update(next, focus: added.id)
    }

    private func move(from line: LiveLine, by offset: Int) -> KeyPress.Result {
        guard let i = lines.firstIndex(where: { $0.id == line.id }), lines.indices.contains(i + offset) else { return .ignored }
        focused = lines[i + offset].id
        return .handled
    }
}

/// The time a line not begun yet will be stamped with: the call's clock, which ticks with the recorder's status.
private struct PendingChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Chip(text: clock(model.recording.started ? model.recording.status.elapsed ?? 0 : 0), style: .pending)
    }
}

// MARK: Bottom bar

/// The levels and the microphone: drawn again with each status from the recorder.
private struct LiveBar: View {
    @Environment(AppModel.self) private var model
    @ViewState private var devices: [InputDevice] = []

    private var status: RecorderStatus { model.recording.status }
    private var started: Bool { model.recording.started }

    private var micStatus: (text: String, color: Color, warn: Bool) {
        guard started else { return (model.recording.recorderFailure != nil ? "Not recording." : status.state == .starting ? "Starting…" : "Recording stopped.", .secondary, false) }
        guard let device = status.micDevice else { return ("No microphone found. Connect one to record your side of the call.", .red, true) }
        if let mic = model.config.mic, device.uid != mic.uid {
            return ("\(mic.name) isn’t connected, so this is recording from \(device.name).", .amber, true)
        }
        return ("Recording from \(device.name).", .secondary, false)
    }

    var body: some View {
        let mic = micStatus
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Meter(label: "You", level: status.micLevel)
                Meter(label: "Call", level: status.systemLevel)
            }
            // The menu on the right names the microphone: this says something only when there's more to say.
            if mic.warn || !started {
                Label(mic.text, systemImage: "mic").font(.callout).foregroundStyle(mic.color).lineLimit(2)
            }
            Spacer()
            Menu {
                Section("Microphone") {
                    ForEach(micChoices(model.config.mic, devices), id: \.value) { choice in
                        Button {
                            model.setMic(chooseMic(choice.value, devices, current: model.config.mic))
                        } label: {
                            if (model.config.mic?.uid ?? "") == choice.value { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                        }
                    }
                }
                Divider()
                Text("Call audio is everything your Mac plays. It’s always recorded, so Oatcake can tell the voices apart.")
            } label: {
                Label(status.micDevice?.name ?? model.config.mic?.name ?? "Same as Mac", systemImage: mic.warn ? "exclamationmark.triangle" : "mic")
            }
            .fixedSize()
            .help(mic.text)
            .onTapGesture { Task { devices = (try? await Recordings.listInputs()) ?? devices } }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .task { devices = (try? await Recordings.listInputs()) ?? [] }
    }
}

extension RecordingController {
    /// Audio is arriving: the call's clock is running.
    var started: Bool { status.state == .recording && recorderFailure == nil }
}

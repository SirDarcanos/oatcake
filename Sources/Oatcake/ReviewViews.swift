import AVFoundation
import OatcakeCore
import SwiftUI

/// "October 29th, 2026 · 16:30 · 32 min" for a recording.
func recordingMeta(_ rec: Recording) -> String {
    [longDate(rec.startedAt), hhmm(rec.startedAt), rec.endedAt.map { minutes($0.timeIntervalSince(rec.startedAt)) }]
        .compactMap { $0 }.joined(separator: " · ")
}

/// The failure in plain words; the raw message stays behind "Details".
private func explain(_ failure: AnalysisFailure?) -> String {
    switch failure {
    case .unreadableRecording: "Its recording details couldn’t be read. The files may be damaged or incomplete."
    case .missingAudio: "Some of its audio files are missing."
    case .speechModels: "The speech models couldn’t be loaded. Check your internet connection, then try again."
    case .helperStopped: "The processing helper stopped unexpectedly. Trying again usually works."
    case .other, nil: "Something went wrong while processing this recording. Trying again usually works."
    }
}

struct ProcessingView: View {
    @Environment(AppModel.self) private var model
    let rec: Recording
    @ViewState private var details = false

    var body: some View {
        let progress = model.jobs.progress[rec.id]
        let stage = progress?.stage
        let step = progress?.waiting == true ? "Waiting for another recording to be processed" : stage?.title ?? "Starting"
        let n = stage?.number ?? 1
        let within = progress?.fraction ?? (stage?.isStep == true ? 0.5 : 0.1)
        // The first recording on a Mac fetches the speech models before anything can be transcribed.
        let downloading = stage == .downloadingModels
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pathAbove(rec.folder ?? "", rec.title)).font(.callout).foregroundStyle(.secondary)
                Text(rec.title).font(.title2.weight(.semibold))
                Text(recordingMeta(rec)).font(.callout).foregroundStyle(.secondary)
            }
            if let error = progress?.error {
                Notice(tone: .red) {
                    Text("Couldn’t finish “\(stage?.isStep == true ? step : "Getting the recording ready")”").fontWeight(.semibold)
                    HStack(spacing: 4) {
                        Text(explain(progress?.failure))
                        Button(details ? "Hide details" : "Details") { details.toggle() }.buttonStyle(.link)
                    }
                    if details { Text(error).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 4) }
                }
                HStack {
                    Button("Try again") { model.jobs.retry(rec) }.buttonStyle(.borderedProminent)
                    Button("Discard…") { model.jobs.discard(rec) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(step)…")
                        Spacer()
                        Text("Step \(n) of 5").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    // How long a download takes depends on the connection, so its bar doesn't pretend to know.
                    if downloading {
                        ProgressView().progressViewStyle(.linear).accessibilityLabel("Downloading")
                    } else {
                        ProgressView(value: (Double(n - 1) + within) / 5)
                    }
                }
                let then = model.config.afterCall == .review ? "it’ll wait under Needs review." : "it’ll be saved to \(folderPath(rec.folder ?? "")) when it’s done."
                Text(downloading
                     ? "The speech models (about 500 MB) are downloading. That’s the first time only; after it, an hour-long call takes a minute or two. You can keep working — \(then)"
                     : "An hour-long call takes a minute or two. You can keep working — \(then)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                (Text(progress?.error != nil ? "Couldn’t finish" : "Processing").fontWeight(.semibold) + Text(" · \(rec.title)").foregroundStyle(.secondary)).lineLimit(1)
                    .toolbarStatusPadding()
            }
            .withoutCapsule()
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            if progress?.error == nil {
                ToolbarItem(placement: .automatic) { Button("Discard…") { model.jobs.discard(rec) } }
            }
        }
    }
}

/// Plays the review screen's clips, one at a time.
@MainActor @Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    var playing: String?
    var fraction = 0.0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ file: String) {
        player?.stop()
        timer?.invalidate()
        if playing == file {
            playing = nil
            return
        }
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: file)) else { return }
        p.delegate = self
        player = p
        playing = file
        fraction = 0
        p.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let p = self.player, p.duration > 0 else { return }
                self.fraction = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate()
            self.playing = nil
        }
    }
}

/// Who's who: one card per voice, to name, merge or mark as mixed before saving. The title and the
/// folder it's saved in can be changed here too. For a meeting already saved without checking (Settings ›
/// General › After a call), it names the voices and updates that meeting in place.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let rec: Recording

    typealias Voice = ReviewDraft.Voice

    @ViewState private var analysis: Analysis?
    @ViewState private var people: [String] = []
    @ViewState private var showTranscript = false
    @ViewState private var error = ""
    @ViewState private var saved = false
    @ViewState private var player = ClipPlayer()
    @ViewState private var paneWidth: CGFloat = 900

    /// What's been set so far lives with the app, so leaving this screen and coming back keeps it.
    private var draft: ReviewDraft {
        get { model.jobs.reviewDrafts[rec.id] ?? ReviewDraft(title: rec.title, folder: rec.folder ?? "", voices: [:]) }
        nonmutating set {
            // Anything changed here is what quitting would lose.
            var changed = newValue
            changed.edited = draft.edited || newValue != draft
            model.jobs.reviewDrafts[rec.id] = changed
        }
    }
    private var voices: [String: Voice] {
        get { draft.voices }
        nonmutating set { draft.voices = newValue }
    }
    private var title: String { draft.title.trimmed.isEmpty ? rec.title : draft.title.trimmed }
    /// The recording is already a meeting: saving updates it where it is, under the title it has.
    private var rechecking: Bool { rec.state == .saved }

    var body: some View {
        Group {
            if let analysis {
                HStack(spacing: 0) {
                    ScrollView { cards(analysis).padding(.horizontal, 36).padding(.vertical, 28).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity) }
                    if showTranscript {
                        Divider()
                        transcript(analysis).frame(width: sidePanelWidth(in: paneWidth))
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
                .toolbar { toolbar(analysis) }
            } else if !error.isEmpty {
                unreadable
            } else {
                // Until load() has run: something has to be here for onAppear to be called.
                Color.clear
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            player.stop()
            // Kept while this showed it, so the cards didn't go blank after Save.
            if saved { model.jobs.reviewDrafts.removeValue(forKey: rec.id) }
        }
    }

    /// Its analysis couldn't be read (damaged, or cut short): it can be analysed again, or discarded.
    /// A meeting already saved has nothing to analyse again (its tracks are with the meeting).
    private var unreadable: some View {
        VStack(alignment: .leading, spacing: 18) {
            Notice(tone: .red) {
                Text("Who’s who couldn’t be opened").fontWeight(.semibold)
                Text(error)
            }
            if !rechecking {
                HStack {
                    Button("Try again") { model.jobs.retry(rec) }.buttonStyle(.borderedProminent)
                    Button("Discard…") { model.jobs.discard(rec) }
                }
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                (Text("Who’s who").fontWeight(.semibold) + Text(" · \(title)").foregroundStyle(.secondary)).lineLimit(1)
                    .toolbarStatusPadding()
            }
            .withoutCapsule()
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            if !rechecking {
                ToolbarItem(placement: .automatic) { Button("Discard…") { model.jobs.discard(rec) } }
            }
        }
    }

    private func load() {
        do {
            let a = try loadAnalysis(rec)
            analysis = a
            people = knownPeople()
            if model.jobs.reviewDrafts[rec.id] == nil {
                // As it opens, with nothing changed yet: not through `draft`, which would count it as an edit.
                model.jobs.reviewDrafts[rec.id] = ReviewDraft(title: rec.title, folder: rec.folder ?? "",
                                                              voices: Dictionary(uniqueKeysWithValues: a.speakers.map { ($0.id, Voice(name: $0.suggestion?.name ?? "")) }))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var myName: String { model.config.myName.isEmpty ? "You" : model.config.myName }

    private func label(_ analysis: Analysis, _ id: String) -> String { voiceLabel(analysis, id) }

    /// The name a line will be saved under, following merges.
    private func nameOf(_ analysis: Analysis, _ id: String, _ seen: Set<String> = []) -> String {
        if id == me { return myName }
        guard let v = voices[id] else { return "Unknown" }
        if let into = v.into, !seen.contains(id) { return nameOf(analysis, into, seen.union([id])) }
        return v.mixed ? "Several people" : v.name.trimmed.isEmpty ? label(analysis, id) : v.name.trimmed
    }

    /// Whether a voice's lines are left out of the meeting: it was marked as not part of the call,
    /// or merged into one that was.
    private func leftOut(_ id: String, _ seen: Set<String> = []) -> Bool {
        guard let v = voices[id] else { return false }
        if let into = v.into, !seen.contains(id) { return leftOut(into, seen.union([id])) }
        return v.leftOut
    }

    /// People on the call's calendar invite who haven't been given a voice yet, as quick picks.
    private var invited: [String] {
        let used = Set(voices.values.filter { !$0.leftOut }.map { $0.name.trimmed.lowercased() })
        return (rec.attendees ?? []).filter { !used.contains($0.lowercased()) }
    }

    /// Everyone named here, you first and then by talking time: the order their colours are given in.
    private func names(_ analysis: Analysis) -> [String] {
        [myName] + analysis.speakers.filter { !leftOut($0.id) }.map { nameOf(analysis, $0.id) }
    }

    @ToolbarContentBuilder private func toolbar(_ analysis: Analysis) -> some ToolbarContent {
        let unnamed = analysis.speakers.filter { voices[$0.id]?.into == nil && voices[$0.id]?.mixed == false && voices[$0.id]?.leftOut != true && (voices[$0.id]?.name.trimmed.isEmpty ?? true) }.count
        ToolbarItem(placement: .automatic) {
            (Text("Who’s who").fontWeight(.semibold) + Text(" · \(title)").foregroundStyle(.secondary)).lineLimit(1)
                .toolbarStatusPadding()
        }
        .withoutCapsule()
        if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $showTranscript) { Text("Transcript") }.toggleStyle(.button)
            if !rechecking { Button("Discard…") { model.jobs.discard(rec) }.disabled(saved) }
        }
        if unnamed > 0 {
            ToolbarItem(placement: .automatic) {
                Text("\(unnamed) voice\(unnamed == 1 ? "" : "s") unnamed").font(.callout).foregroundStyle(.secondary)
                    .help("Unnamed voices are saved as “Voice 1”, “Voice 2”…")
                    .toolbarStatusPadding()
            }
            .withoutCapsule()
        }
        ToolbarItem(placement: .automatic) {
            Button(rechecking ? "Update meeting" : "Save") { save(analysis) }
                .buttonStyle(.borderedProminent)
                .disabled(saved)
                .help(rechecking ? "Rewrite the meeting’s transcript with these names, and use them in its summary and to-dos."
                      : "Save the meeting. Its summary is written straight after.")
        }
    }

    private func cards(_ analysis: Analysis) -> some View {
        let visible = analysis.speakers.filter { voices[$0.id]?.into == nil }
        let meTalk = analysis.me?.seconds ?? analysis.lines.filter { $0.speaker == me }.reduce(0) { $0 + $1.end - $1.start }
        let colors = provisionalColors(names(analysis))
        let folders = (model.library.tree?.allFolders ?? []).map(\.path)
        return VStack(alignment: .leading, spacing: 16) {
            if rechecking {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rec.title).font(.system(size: 22, weight: .bold))
                    Text(recordingMeta(rec)).foregroundStyle(.secondary)
                    Text("This meeting was saved without checking who’s who. Name the voices, then Update meeting: its transcript is written again with these names, and they replace the old ones in its summary and to-dos. Your notes stay as they are.")
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Folder", selection: Binding(get: { draft.folder }, set: { draft.folder = $0 })) {
                        Text("Meetings (top level)").tag("")
                        ForEach(folders, id: \.self) { Text(folderPath($0)).tag($0) }
                        // The folder it was recorded for has since gone: saving makes it again.
                        if !draft.folder.isEmpty && !folders.contains(draft.folder) { Text(folderPath(draft.folder)).tag(draft.folder) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, -8)
                    .help("The folder this meeting is saved in")
                    TextField("Title", text: Binding(get: { draft.title }, set: { draft.title = $0 }), prompt: Text(rec.title))
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold))
                        .help("The meeting’s title")
                    Text(recordingMeta(rec)).foregroundStyle(.secondary)
                    Text("Check who’s who before saving. Names label the transcript, and Oatcake remembers these voices next time.")
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            if !error.isEmpty { Notice(tone: .red) { Text(error) } }
            if analysis.speakers.isEmpty {
                Notice(tone: .amber) {
                    Text("No other voices were heard").fontWeight(.semibold)
                    Text("Only your microphone picked anything up. If people were talking on the call, check that Oatcake is allowed in System Settings › Privacy & Security › Screen & System Audio Recording.")
                }
            }
            // Why the model's name suggestions were skipped, in plain words.
            if let error = analysis.nameSuggestionError {
                Notice(tone: .amber) { ModelError(raw: error, prefix: "Names weren’t suggested for this call. ") }
            }
            ForEach(analysis.warnings, id: \.self) { w in
                Notice(tone: .amber) { Text(w) }
            }

            card {
                HStack(spacing: 10) {
                    Avatar(name: myName, size: 30, remember: false, color: colors[myName])
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(myName) · your microphone").fontWeight(.semibold)
                        Text("\(minutes(meTalk)) talking").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let quotes = analysis.me?.quotes, !quotes.isEmpty { clips(quotes) }
                Text("Labelled with your name from Settings.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(visible, id: \.id) { s in voiceCard(analysis, s, visible: visible, colors: colors) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
    }

    private func voiceCard(_ analysis: Analysis, _ s: SpeakerInfo, visible: [SpeakerInfo], colors: [String: Color]) -> some View {
        let v = voices[s.id] ?? Voice(name: "")
        // Left out, it goes by its number whatever name it had: nobody of that name is in the meeting.
        let shown = v.leftOut ? label(analysis, s.id) : v.mixed ? "Several people" : v.name.trimmed.isEmpty ? label(analysis, s.id) : v.name.trimmed
        let absorbed = analysis.speakers.filter { voices[$0.id]?.into == s.id }
        let fromSuggestion = s.suggestion.map { v.name == $0.name && !v.mixed } ?? false
        let targets = visible.filter { $0.id != s.id && voices[$0.id]?.mixed != true && voices[$0.id]?.leftOut != true }
        return card {
            HStack(spacing: 10) {
                Avatar(name: shown, size: 30, remember: false, color: v.mixed ? Color(nsColor: .systemGray) : colors[shown])
                VStack(alignment: .leading, spacing: 1) {
                    Text(shown).fontWeight(.semibold)
                    Text("\(v.leftOut || (v.name.trimmed.isEmpty && !v.mixed) ? "" : "\(label(analysis, s.id)) · ")\(minutes(s.seconds)) talking")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                // Merge into another voice (or you), mark as mixed, or leave out of the meeting.
                Menu {
                    if v.leftOut {
                        Button("Put back") { voices[s.id]?.leftOut = false }
                    } else {
                        if !v.mixed {
                            Menu("Merge with") {
                                Button("\(myName) (your microphone)") { voices[s.id]?.into = me }
                                ForEach(targets, id: \.id) { o in
                                    Button(voices[o.id].map { $0.name.trimmed.isEmpty ? label(analysis, o.id) : $0.name.trimmed } ?? label(analysis, o.id)) {
                                        voices[s.id]?.into = o.id
                                    }
                                }
                            }
                        }
                        Button(v.mixed ? "Not mixed" : "Mark as mixed (several people)") { voices[s.id]?.mixed.toggle() }
                        Button("Leave out (not part of the call)") {
                            voices[s.id]?.mixed = false
                            voices[s.id]?.leftOut = true
                        }
                    }
                } label: {
                    // The words are the button's own title, with only the icon drawn. A label added to the
                    // menu from outside was lost whenever the card was drawn again, leaving the icon's "More".
                    Label(v.leftOut ? "Put \(shown) back in the meeting" : "Merge \(shown) with another voice, mark it as mixed, or leave it out",
                          systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(v.leftOut ? "Put back" : "Merge, mark as mixed or leave out")
            }
            clips(s.quotes)
            if !v.mixed && !v.leftOut {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Who is this?", text: Binding(get: { voices[s.id]?.name ?? "" }, set: {
                        if $0 != voices[s.id]?.name { voices[s.id]?.fromInvite = false }
                        voices[s.id]?.name = $0
                    }))
                        .textFieldStyle(.roundedBorder)
                        .textInputSuggestions {
                            ForEach((people + (rec.attendees ?? []).filter { !people.contains($0) }).filter { p in let typed = v.name.trimmed.lowercased(); return !typed.isEmpty && p.lowercased().contains(typed) && p != v.name }, id: \.self) {
                                Text($0).textInputCompletion($0)
                            }
                        }
                    // The people on the calendar invite not yet given a voice: one click names this one.
                    if !invited.isEmpty {
                        FlowLayout(spacing: 6) {
                            Text("On the invite:").font(.callout).foregroundStyle(.secondary)
                            ForEach(invited.prefix(8), id: \.self) { name in
                                Button(name) { voices[s.id] = Voice(name: name, fromInvite: true) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .help("Name this voice \(name)")
                            }
                        }
                    }
                    if v.fromInvite && !v.name.trimmed.isEmpty {
                        Label("From the calendar invite", systemImage: "calendar").font(.callout).foregroundStyle(.secondary)
                    } else if fromSuggestion, let suggestion = s.suggestion {
                        Label {
                            switch suggestion.how {
                            case .voice: Text("Recognised from before")
                            case .live: Text("Named by you during the call")
                            case .transcript:
                                Text("Guessed from the conversation\(suggestion.detail.isEmpty ? "" : " · “\(suggestion.detail.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")))”")")
                            }
                        } icon: {
                            switch suggestion.how {
                            case .voice: Image(systemName: "person.crop.circle.badge.checkmark")
                            case .live: Image(systemName: "text.bubble")
                            case .transcript: Image(systemName: "quote.bubble")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(suggestion.how == .voice ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                }
            }
            if v.leftOut {
                Text("Not part of the call, so its lines are left out of the meeting: they won’t be in the transcript, the summary or the to-dos.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if v.mixed || !absorbed.isEmpty {
                HStack(spacing: 4) {
                    Text(v.mixed ? "More than one person shares this voice, so their lines will be labelled “Several people”."
                         : "Includes \(absorbed.map { label(analysis, $0.id) }.joined(separator: ", ")).")
                    if !v.mixed && !absorbed.isEmpty {
                        Button("Undo") { for o in absorbed { voices[o.id]?.into = nil } }.buttonStyle(.link)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func clips(_ quotes: [Quote]) -> some View {
        HStack(spacing: 8) {
            ForEach(quotes, id: \.clip) { q in
                let on = player.playing == q.clip
                Button { player.toggle(q.clip) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 9))
                        Text(clock(q.start)).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(on ? "Pause" : "Play") the clip at \(clock(q.start))")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Color.accentColor.opacity(0.18)).frame(width: on ? g.size.width * player.fraction : 0)
                        }
                    }
                    .background(Capsule().fill(Color.fill))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(q.text)
            }
        }
    }

    private func transcript(_ analysis: Analysis) -> some View {
        // The names are text here, so each person's colour is in the shade that reads against the window.
        let colors = provisionalNameColors(names(analysis))
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Transcript")
                    Spacer()
                    Text("Updates as you name voices").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(analysis.lines.enumerated()).filter { !leftOut($0.element.speaker) }, id: \.offset) { _, l in
                    let name = nameOf(analysis, l.speaker)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(name).fontWeight(.semibold).foregroundStyle(colors[name].map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                            Text(clock(l.start)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.caption)
                        Text(l.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Saving writes the meeting straight away; its summary is then written in the background and
    /// appears in the meeting when it's ready.
    private func save(_ analysis: Analysis) {
        error = ""
        // An unnamed voice is sent with no name: it's saved as "Voice N" but never remembered as a person.
        let decisions = voices.mapValues { v -> Decision in
            if let into = v.into { return .merge(into: into) }
            if v.leftOut { return .ignore }
            return v.mixed ? .mixed : .name(v.name.trimmed)
        }
        let folder = draft.folder
        let everyone = names(analysis)
        do {
            let path = rechecking ? try model.jobs.updateMeeting(rec, decisions: decisions)
                : try model.jobs.saveRecording(rec, decisions: decisions, folder: folder, title: title)
            saved = true
            // Colours are claimed in the order this screen showed them, so nobody changes colour on saving.
            for name in everyone { _ = person(name) }
            player.stop()
            model.refresh()
            model.toast(rechecking ? "Meeting updated" : "Saved to \(folderPath(folder))")
            // On to the meeting now, as saving by itself does: it shows as soon as the folder has been read
            // again, however long that takes. On its summary, whichever tab you last read another meeting
            // on: that's where the summary arrives.
            model.folder = parentOf(path)
            model.selection = .meeting(path, jump: Jump(tab: rechecking ? .transcript : .summary))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

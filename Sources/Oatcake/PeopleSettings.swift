import OatcakeCore
import SwiftUI

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
struct PeopleSection: View {
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
                            Menu("Merge into") {
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
        return voice.lastSaved.map { "\(calls) · last \(compactDate($0))" } ?? calls
    }
}

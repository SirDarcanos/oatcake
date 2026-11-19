// Rename speakers…: the names a saved meeting's transcript gives its speakers, each with a field for
// another name. Only that meeting changes (Meetings.renameSpeakers).

import OatcakeCore
import SwiftUI

struct RenameSpeakersSheet: View {
    let speakers: [MeetingSpeaker]
    let rename: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var names: [String: String] = [:]

    /// The names that change: a field left blank, or as it was, leaves that speaker alone.
    private var changes: [String: String] {
        names.mapValues(\.trimmed).filter { !$0.value.isEmpty && $0.key != $0.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename speakers").font(.headline)
            Text("Changes this meeting only: the names in its transcript, summary and to-dos. Give two speakers the same name to make them one. A voice Oatcake learnt from this call goes with its new name.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(speakers) { s in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text("[\(s.firstAt)] \(s.firstWords)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(s.firstWords)
                        }
                        .frame(width: 210, alignment: .leading)
                        TextField("", text: Binding(get: { names[s.name] ?? s.name }, set: { names[s.name] = $0 }), prompt: Text(s.name))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("New name for \(s.name)")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    rename(changes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

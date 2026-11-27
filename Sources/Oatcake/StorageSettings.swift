import OatcakeCore
import SwiftUI

extension SettingsView {
    /// Other apps' MCP access to the Meetings folder. They start `Oatcake --mcp` themselves, so
    /// there's nothing here to start or stop: only whether it may read, and what to give an app.
    var mcp: some View {
        Section {
            Toggle("Let other apps read my meetings", isOn: bind(\.mcpEnabled))
            if model.mcpOffNotSaved, !model.config.mcpEnabled {
                Text("Oatcake couldn’t save this, so apps you’ve added it to can still read your meetings.")
                    .settingsHint(.amber)
                Button("Retry saving") { model.retrySavingMCPOff() }
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

    @ViewBuilder var storage: some View {
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

    /// "~/Documents/…/Meetings": long paths lose their middle; hover shows the full path.
    private func shortPath(_ full: String) -> String {
        let p = full.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
        return p.count <= 46 ? p : "\(p.prefix(20))…\(p.suffix(24))"
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

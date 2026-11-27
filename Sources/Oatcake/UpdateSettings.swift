import OatcakeCore
import SwiftUI

/// Settings › Updates: this version, Check now, and the newer release when there is one.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var copied = false
    @ViewState private var confirming = false

    var body: some View {
        let u = model.updater
        Section("Updates") {
            LabeledContent {
                Button("Check now") { Task { await u.check() } }.disabled(u.checking || u.installing != nil)
            } label: {
                Text("Oatcake \(u.current)")
                Text(u.error ?? status(u)).foregroundStyle(u.error != nil ? Color.red : Color.secondary)
            }
            if let available = u.available {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What’s new in \(available.version)")
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
                            Button(u.installing ?? "Install and relaunch…") { confirming = true }
                                .buttonStyle(.borderedProminent).disabled(u.installing != nil)
                                .installQuestion(available.version, isPresented: $confirming) { Task { await u.install() } }
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
        if let checked = u.checkedAt { return "Up to date · checked at \(timeOfDay(checked))" }
        return "Not checked yet."
    }
}

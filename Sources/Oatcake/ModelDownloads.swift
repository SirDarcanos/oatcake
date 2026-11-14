// The language model's file: whether it's on this Mac, fetching it, and removing it.

import Foundation
import OatcakeCore
import SwiftUI

@MainActor @Observable
final class ModelDownloads {
    /// What this part asks of the app around it.
    var app = AppServices()
    private var config: Config { app.config() }

    /// How far each language model's download has got (0 to 1) while one is under way, and why the
    /// last one stopped, by model.
    var modelDownloads: [String: Double] = [:]
    var modelDownloadErrors: [String: String] = [:]
    /// Bumps when a model's file arrives or is removed, so Settings looks at the disk again.
    var modelsVersion = 0
    private var modelDownloadTasks: [String: Task<Void, Error>] = [:]

    /// The model chosen in Settings, when it's one Oatcake downloads and runs itself.
    var chosenModel: LocalModel? { LocalModels.find(config.llm.model) }

    /// "Downloading the language model: 42% of 5.0 GB", while the chosen one is on its way.
    var modelDownloadStatus: String? {
        guard let chosenModel, let fraction = modelDownloads[chosenModel.id] else { return nil }
        return "Downloading the language model: \(Int(fraction * 100))% of \(chosenModel.downloadSize)"
    }

    /// Starts downloading a model, or joins the download already under way.
    @discardableResult
    func downloadModel(_ model: LocalModel) -> Task<Void, Error> {
        if let task = modelDownloadTasks[model.id] { return task }
        modelDownloadErrors.removeValue(forKey: model.id)
        modelDownloads[model.id] = 0
        let task = Task {
            defer {
                modelDownloadTasks.removeValue(forKey: model.id)
                modelDownloads.removeValue(forKey: model.id)
                modelsVersion += 1
            }
            // A connection that drops part-way is tried again by itself, a little later each time: the
            // file carries on from where it stopped. Not after Stop, and not when the download never
            // got going (no room on the disk, a refusal from the server) or failed after it was whole.
            var waits = [5, 15, 45]
            while true {
                let reached = Furthest()
                do {
                    try await ModelDownload.fetch(model) { fraction in
                        reached.note(fraction)
                        Task { @MainActor in
                            if self.modelDownloadTasks[model.id] != nil { self.modelDownloads[model.id] = fraction }
                        }
                    }
                    return
                } catch {
                    if isCancellation(error) { throw error }
                    let dropped = reached.value >= 0 && reached.value < 0.999
                    guard dropped, !waits.isEmpty else {
                        modelDownloadErrors[model.id] = error.localizedDescription
                        throw error
                    }
                    try await Task.sleep(for: .seconds(waits.removeFirst()))
                }
            }
        }
        modelDownloadTasks[model.id] = task
        return task
    }

    func stopModelDownload(_ model: LocalModel) { modelDownloadTasks[model.id]?.cancel() }

    /// Deletes a model's file, stopping its download or the model itself first.
    func removeModel(_ model: LocalModel) {
        let download = modelDownloadTasks[model.id]
        download?.cancel()
        Task {
            _ = try? await download?.value
            await ModelServer.shared.stop()
            LocalModels.remove(model)
            modelsVersion += 1
        }
    }

    /// Waits for the chosen model to be on this Mac, downloading it if it isn't. A server of your
    /// own needs nothing.
    func ensureModel() async throws {
        guard let chosenModel, !LocalModels.isDownloaded(chosenModel) else { return }
        let download = downloadModel(chosenModel)
        // Looked at again every so often, so that whatever is waiting (a question, say) can be
        // stopped without stopping the download.
        while modelDownloadTasks[chosenModel.id] != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
        }
        do {
            try await download.value
        } catch where isCancellation(error) {
            // The download was stopped (in Settings), not what was waiting for it.
            throw OatcakeError(modelNotDownloadedMessage)
        }
    }

    /// Whether any model is on its way down.
    var isDownloading: Bool { !modelDownloadTasks.isEmpty }
}

/// How far a download attempt got, noted from whichever thread reports it.
private final class Furthest: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction = -1.0
    var value: Double { lock.withLock { fraction } }
    func note(_ f: Double) { lock.withLock { fraction = max(fraction, f) } }
}

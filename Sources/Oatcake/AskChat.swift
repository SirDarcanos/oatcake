import Foundation
import OatcakeCore
import SwiftUI

struct AskTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String?
    var error: String?
    var stopped = false
    var step: String?
    var startedAt = Date()
    var running: Bool { answer == nil && error == nil && !stopped }
}

/// One conversation for as long as the app is open. It carries on as you move between meetings, so
/// following a link in an answer doesn't lose it. From Home there's no open meeting to start with.
@MainActor @Observable
final class AskChat {
    var turns: [AskTurn] = []
    var open = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var running: AskTurn? { turns.first(where: \.running) }

    func send(_ question: String, meeting: String?, config: Config, downloads: ModelDownloads, meetings: Meetings) {
        let history = turns.compactMap { turn in turn.answer.map { AskExchange(question: turn.question, answer: $0) } }
        let turn = AskTurn(question: question)
        turns.append(turn)
        open = true
        tasks[turn.id] = Task {
            do {
                // The first question may find the model still on its way.
                let waiting = Task {
                    while !Task.isCancelled {
                        if let status = downloads.modelDownloadStatus { update(turn.id) { $0.step = status } }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                defer { waiting.cancel() }
                try await downloads.ensureModel()
                waiting.cancel()
                let answer = try await OatcakeCore.ask(config, meeting: meeting, question: question, history: history, meetings: meetings) { step in
                    Task { @MainActor in self.update(turn.id) { $0.step = step } }
                }
                update(turn.id) { $0.answer = answer }
            } catch {
                let message = error.localizedDescription
                update(turn.id) { if Task.isCancelled || isCancellation(error) { $0.stopped = true } else { $0.error = message } }
            }
            tasks.removeValue(forKey: turn.id)
        }
    }

    func cancel() {
        if let running { tasks[running.id]?.cancel() }
    }

    func newChat() {
        turns = []
        open = true
    }

    private func update(_ id: UUID, _ change: (inout AskTurn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { change(&turns[i]) }
    }
}

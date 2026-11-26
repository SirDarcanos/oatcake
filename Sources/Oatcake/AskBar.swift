import OatcakeCore
import SwiftUI

private let meetingSuggestions = [
    "What did we decide in this call?",
    "What’s still open from earlier meetings like this one?",
    "Who said they’d follow up, and on what?",
]

/// The floating "ask about your meetings" lozenge; the conversation opens above it.
struct AskBar: View {
    @Environment(AppModel.self) private var model
    let path: String?
    @ViewState private var draft = ""
    @FocusState private var focused: Bool
    /// The conversation's own height: the panel is as tall as that, up to its limit.
    @ViewState private var contentHeight: CGFloat = 0
    @AppStorage(TextScale.key) private var textScale = 1.0

    private var placeholder: String {
        if !model.ask.turns.isEmpty { return "Ask a follow-up…" }
        return path == nil ? "Ask about your meetings…" : "Ask about this meeting, or any other…"
    }

    /// From Home, Ask finds calls by the words in the question, so these name the latest calls.
    private var homeSuggestions: [String] {
        let latest = newestIn(model.library.tree, 2).map(meetingTitle)
        guard let newest = latest.first else { return [] }
        var questions = ["What did we decide in “\(newest)”?", "Who said they’d follow up after “\(newest)”, and on what?"]
        if latest.count > 1 { questions.append("What’s still open from “\(latest[1])”?") }
        return questions
    }

    var body: some View {
        let chat = model.ask
        VStack(spacing: 10) {
            if chat.open { panel(chat) }
            HStack(spacing: 8) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { submit() }
                if chat.running != nil {
                    Button { chat.cancel() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                        .buttonStyle(RoundButtonStyle(filled: true)).help("Stop").accessibilityLabel("Stop")
                } else {
                    Button { submit() } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(RoundButtonStyle(filled: !draft.trimmed.isEmpty)).help("Send (Return)").accessibilityLabel("Send")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.line))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .onChange(of: focused) { if focused, !chat.turns.isEmpty { chat.open = true } }
        // Edit › Ask About Your Meetings (⌘L).
        .onChange(of: model.askRequest) { focused = true }
    }

    private func submit(_ text: String? = nil) {
        let question = (text ?? draft).trimmed
        guard !question.isEmpty, model.ask.running == nil else { return }
        draft = ""
        model.ask.send(question, meeting: path, config: model.config, downloads: model.downloads, meetings: model.library.meetings)
    }

    private func panel(_ chat: AskChat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask about your meetings").font(.headline)
                Spacer()
                Button("New chat") { chat.newChat(); focused = true }.disabled(chat.running != nil)
                // Escape hides it wherever the keyboard is, not only from its field. Not while search is
                // over the window: Escape is search's then.
                Button("Hide") {
                    chat.open = false
                    focused = false
                }
                .help("Hide (Esc)")
                .keyboardShortcut(model.searching ? nil : .cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.turns) { turn in turnView(turn).id(turn.id) }
                        if chat.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask anything across your meetings. Answers link to the meetings they draw on.").foregroundStyle(.secondary)
                                ForEach(path == nil ? homeSuggestions : meetingSuggestions, id: \.self) { q in
                                    Button(q) { submit(q) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                // Show the newest question at the top, so a long answer is read from its start.
                .onChange(of: chat.turns.count) { if let last = chat.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } } }
            }
            // As tall as the conversation, up to 420 points; a short answer isn't put in a tall empty panel.
            .frame(height: min(max(contentHeight, 60), 420))
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
        .frame(maxWidth: 640)
        .environment(\.openURL, OpenURLAction { url in
            if let rel = meetingPath(from: url) {
                // A citation with a time opens the transcript there.
                model.openMeeting(rel, jump: meetingStamp(from: url).map { Jump(tab: .transcript, stamp: $0) })
                return .handled
            }
            return .discarded
        })
    }

    private func turnView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).fontWeight(.semibold)
            if let answer = turn.answer {
                // One piece of text, so the whole answer (or any stretch of it) can be selected and copied.
                SelectableMarkdown(markdown: answerMarkdown(answer), fontSize: 13 * TextScale.clamped(textScale)) { model.ask.open = false }
            } else if let error = turn.error {
                ModelError(raw: error).foregroundStyle(.red).textSelection(.enabled)
            } else if turn.stopped {
                Text("Stopped.").foregroundStyle(.secondary)
            } else {
                // The elapsed-time counter while an answer is on its way.
                TimelineView(.periodic(from: turn.startedAt, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(turn.step ?? "Thinking")…").lineLimit(1)
                        Text("\(Int(context.date.timeIntervalSince(turn.startedAt))) s").foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RoundButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 28, height: 28)
            .background(Circle().fill(filled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.fill)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

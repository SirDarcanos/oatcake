import OatcakeCore
import SwiftUI

extension MeetingView {
    /// The words being looked for, while Find is open.
    var findWords: [String] { finding ? searchWords(query) : [] }

    /// The rows that have every word being looked for, as search finds a meeting.
    func matches(in rows: [Row]) -> [Int] {
        let words = searchWords(query)
        guard !words.isEmpty else { return [] }
        return rows.indices.filter { i in words.allSatisfy { rows[i].text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
    }

    func findBar(_ found: [Int], stepping: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(stepping ? "Find in transcript" : "Find", text: $query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(1, found) }
                .onChange(of: query) { match = 0 }
            // Stepping through matches is the transcript's; elsewhere the words are only marked.
            if stepping {
                Text(query.trimmed.isEmpty ? "" : found.isEmpty ? "Not found" : "\(min(match, found.count - 1) + 1) of \(found.count)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button { step(-1, found) } label: { Image(systemName: "chevron.up") }.disabled(found.isEmpty).help("Previous (⇧⌘G)").accessibilityLabel("Previous match")
                Button { step(1, found) } label: { Image(systemName: "chevron.down") }.disabled(found.isEmpty).help("Next (Return or ⌘G)").accessibilityLabel("Next match")
            }
            // Escape closes it wherever the keyboard is, not only from its field. Not while Ask is open
            // over it (Escape closes that first) or search is: Escape is theirs then.
            Button("Done") { endFind() }.help("Close (Esc)")
                .keyboardShortcut(model.ask.open || model.searching ? nil : .cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    func step(_ by: Int, _ found: [Int]) {
        guard !found.isEmpty else { return }
        match = (min(match, found.count - 1) + by + found.count) % found.count
    }

    private func endFind() {
        finding = false
        findFocused = false
        query = ""
        match = 0
    }

    /// The text with what's being looked for marked.
    func marked(_ text: String) -> AttributedString { markingFound(text, findWords) }
}

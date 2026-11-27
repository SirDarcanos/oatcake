import OatcakeCore
import SwiftUI

extension MeetingView {
    func notes(_ files: [FileKey: String]) -> some View {
        let notes = parseNotes(files[.notes] ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Chip(text: n.stamp ?? "Prep", style: n.stamp == nil ? .prep : .normal)
                    Text(marked(n.text)).font(.system(size: 13 * scale)).textSelection(.enabled)
                }
            }
            if notes.isEmpty {
                Text(granola ? "No notes. Granola didn’t keep your notes when this meeting was imported." : "You didn’t take notes in this meeting.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

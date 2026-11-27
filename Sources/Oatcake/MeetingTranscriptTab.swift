import OatcakeCore
import SwiftUI

extension MeetingView {
    // MARK: Transcript

    /// A line of the transcript as shown; one without a speaker is a plain paragraph.
    struct Row {
        var speaker: String?
        var stamp = ""
        var at: Double?
        var text: String
    }

    func transcript(_ rows: [Row], current: Int?) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                // A long turn is several paragraphs: the ones after the first show only their time.
                let continued = i > 0 && row.speaker != nil && rows[i - 1].speaker == row.speaker
                HStack(alignment: .top, spacing: 10) {
                    if let speaker = row.speaker {
                        Avatar(name: speaker, size: 24).opacity(continued ? 0 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                if !continued { Text(speaker).fontWeight(.semibold) }
                                transcriptTime(row)
                            }
                            .font(.callout)
                            Text(marked(row.text)).font(.system(size: 14 * scale)).lineSpacing(3).textSelection(.enabled)
                        }
                    } else {
                        Text(marked(row.text)).font(.system(size: 14 * scale)).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, continued ? 3 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(i == flash || i == current ? Color.orange.opacity(0.16) : .clear))
                .id(i)
            }
            if rows.isEmpty { Text("This meeting has no transcript.").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func transcriptTime(_ row: Row) -> some View {
        if let at = row.at, recordingAudio != nil, at < playback.duration {
            // The same chip as a to-do's or a note's time.
            Chip(text: row.stamp, help: "Go to this moment in the recording") { playback.seek(to: at) }
        } else {
            Text(row.stamp).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

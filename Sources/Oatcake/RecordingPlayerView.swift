import OatcakeCore
import SwiftUI

struct RecordingPlayerView: View {
    let url: URL?
    let playback: RecordingPlayback
    let showInFinder: () -> Void
    @ViewState private var recordingRemoved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url { controls(url) }
            if let failure = recordingRemoved ? .missingFile : playback.failure {
                message(for: failure)
            }
        }
        .padding(.top, url != nil || recordingRemoved ? 12 : 0)
        .onChange(of: url) { old, new in
            // Don't silently lose the player if Finder removes audio someone was trying to hear.
            recordingRemoved = old != nil && new == nil && (playback.duration > 0 || playback.failure != nil)
            playback.stop()
            if let new { playback.prepare(new) }
        }
        .onAppear { if let url { playback.prepare(url) } }
        .task(id: playback.isPlaying) {
            while playback.isPlaying && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { break }
                playback.refreshPosition()
            }
        }
        .onDisappear { playback.stop() }
    }

    private func controls(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Button { playback.toggle(url) } label: {
                if playback.duration > 0 {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                } else {
                    Label("Play recording", systemImage: "play.fill")
                }
            }
            .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")
            .help(playback.isPlaying ? "Pause recording" : "Play recording")

            if playback.duration > 0 {
                Slider(value: Binding(get: { playback.elapsed }, set: { playback.seek(to: $0) }),
                       in: 0...playback.duration) { Text("Recording position") }
                    .labelsHidden()
                    .accessibilityValue("\(clock(playback.elapsed)) of \(clock(playback.duration))")
                Text("\(clock(playback.elapsed)) / \(clock(playback.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: 380, alignment: .leading)
    }

    private func message(for failure: RecordingPlayback.Failure) -> some View {
        let message: LocalizedStringKey = switch failure {
        case .missingFile:
            "Unable to play this recording: the audio file is no longer in the meeting folder. [Show in Finder](oatcake-action://show-in-finder) to check the folder."
        case .accessDenied:
            "Unable to play this recording: Oatcake doesn’t have permission to read the audio file. [Show in Finder](oatcake-action://show-in-finder) to check its permissions."
        case .unreadableFile:
            "Unable to play this recording: the audio file couldn’t be read. [Show in Finder](oatcake-action://show-in-finder) and try playing the file manually."
        case .playbackFailed:
            "Unable to play this recording: playback failed. [Show in Finder](oatcake-action://show-in-finder) and try playing the file manually."
        }
        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .environment(\.openURL, OpenURLAction { url in
                guard url.absoluteString == "oatcake-action://show-in-finder" else { return .discarded }
                showInFinder()
                return .handled
            })
    }
}

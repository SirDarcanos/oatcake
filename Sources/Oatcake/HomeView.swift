import AppKit
import OatcakeCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPane") private var settingsPane = "general"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("Home").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if model.recording.live != nil {
                        Button { model.selection = .live } label: {
                            Label("Return to recording", systemImage: "waveform")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button { model.newRecording() } label: {
                            Label("New recording", systemImage: "circle.fill")
                                .labelStyle(NewRecordingLabelStyle())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                upcoming
                if model.config.todosEnabled { TodosView(homePreview: true) }
                recent
            }
            .padding(28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                heading("Upcoming")
                Spacer()
                if model.calendar.cache != nil {
                    Button { model.calendar.refresh(force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: model.calendar.fetching)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh calendar")
                    .help("Refresh calendar")
                    .disabled(model.calendar.fetching)
                }
            }
            if let cache = model.calendar.cache {
                let now = model.calendar.now
                let events = upcomingCalls(model.calendar.events, at: now)
                if cache.error != nil {
                    Label(events.isEmpty ? "Couldn’t update the calendar." : "Couldn’t update the calendar. Showing the last fetched events.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                } else if cache.updatedAt == nil {
                    Text("Fetching your calendar…").foregroundStyle(.secondary)
                } else if events.isEmpty {
                    Text("No more meetings today or tomorrow.").foregroundStyle(.secondary)
                }
                if !events.isEmpty {
                    let first = events.first?.id
                    rows {
                        ForEach(events) { event in
                            if event.id != first { Divider() }
                            callRow(event, now: now, first: event.id == first)
                        }
                    }
                }
            } else {
                Text("Connect your calendar to see what’s coming up.").foregroundStyle(.secondary)
                Button("Connect calendar") {
                    settingsPane = "calendar"
                    openSettings()
                }
            }
        }
    }

    private func callRow(_ event: CalendarEvent, now: Date, first: Bool) -> some View {
        let day = Calendar.current.isDate(event.startDate, inSameDayAs: now) ? "Today" : "Tomorrow"
        let time = event.startDate <= now ? "In progress" : "\(day) at \(hhmm(event.startDate))"
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).fontWeight(first ? .semibold : .regular)
                Text(first && event.startDate > now ? "Next · \(time)" : time)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let link = event.callLink, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Join the call", systemImage: "video")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Join the call: \(event.title)")
            }
            if model.recording.live == nil {
                Button { model.newRecording(event) } label: {
                    Label("Start recording", systemImage: "circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .accessibilityLabel("Start recording: \(event.title)")
            }
        }
        .padding(.vertical, 10)
    }

    private var recent: some View {
        let meetings = Array(listedIn(model.library.tree).prefix(10))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                heading("Recent meetings")
                Spacer()
                if !meetings.isEmpty {
                    Button("View all meetings") { model.openFolder("") }.buttonStyle(.link)
                }
            }
            if meetings.isEmpty {
                Text("No saved meetings yet.").foregroundStyle(.secondary)
            } else {
                rows {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                        ForEach(meetings, id: \.path) { meeting in
                            if meeting.path != meetings.first?.path {
                                Divider().gridCellUnsizedAxes(.horizontal)
                            }
                            GridRow {
                                Button { model.openMeeting(meeting.path) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                                        Text(meetingTitle(meeting)).foregroundStyle(.primary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                HStack { folderBreadcrumb(parentOf(meeting.path)) }
                                    .frame(maxWidth: 240, alignment: .trailing)
                                    .gridCellAnchor(.trailing)
                                if let date = meetingDate(meeting) {
                                    Text(date, format: .dateTime.year().month(.abbreviated).day())
                                        .font(.callout).foregroundStyle(.secondary)
                                        .gridCellAnchor(.trailing)
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]).accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func folderBreadcrumb(_ folder: String) -> some View {
        let parts = folder.split(separator: "/")
        if !parts.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                ForEach(parts.indices, id: \.self) { index in
                    let path = parts.prefix(index + 1).joined(separator: "/")
                    if index > 0 { Text("/").foregroundStyle(.secondary).accessibilityHidden(true) }
                    Button(String(parts[index])) { model.openFolder(path) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help("Open \(parts.prefix(index + 1).joined(separator: " / "))")
                }
            }
            .font(.caption)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func rows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false) }
    }
}

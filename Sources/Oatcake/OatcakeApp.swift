import AppKit
import OatcakeCore
import SwiftUI
import UserNotifications

struct OatcakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Oatcake", id: "main") {
            ContentView()
                .environment(delegate.model)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 880)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: delegate.model) }

        // Settings is its own window, like a Mac app's Settings. Changes apply as they're made.
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// What File › Move to Trash does. The meeting list sets it while it has the keyboard; anywhere else
/// there's nothing to do, the command is off, and ⌘⌫ keeps its usual meaning (in a text field, say).
struct TrashMeetingsKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var trashMeetings: (() -> Void)? {
        get { self[TrashMeetingsKey.self] }
        set { self[TrashMeetingsKey.self] = newValue }
    }
}

/// File › New Recording and Move to Trash, and Edit › Find in Transcript and Search Meetings.
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.trashMeetings) private var trashMeetings
    @AppStorage(TextScale.key) private var textScale = 1.0
    let model: AppModel

    var body: some Commands {
        // The menus are built at launch, before (and whether or not) the window is: this is where
        // the app learns how to open it, for the menu bar item, reminders and launch itself.
        let _ = model.openMainWindow = { openWindow(id: "main") }
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { model.newRecording() }.keyboardShortcut("n")
            // The sidebar's own buttons for these sit in section headers, out of reach of the keyboard and VoiceOver.
            Button("New Folder") { model.wantsNewFolder = true; model.showWindow() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Refresh Calendar") { model.calendar.refresh(force: true) }.keyboardShortcut("r").disabled(model.calendar.cache == nil)
            Divider()
            // As in Finder. A menu command, because a key handler on the list didn't answer to ⌘⌫.
            Button("Move to Trash") { trashMeetings?() }.keyboardShortcut(.delete, modifiers: .command).disabled(trashMeetings == nil)
        }
        // View › the size of reading text: summaries, answers, transcripts, notes and the Markdown editors.
        CommandGroup(before: .toolbar) {
            Button("Bigger Text") { textScale = TextScale.bigger(textScale) }.keyboardShortcut("+").disabled(textScale >= TextScale.steps.last!)
            Button("Smaller Text") { textScale = TextScale.smaller(textScale) }.keyboardShortcut("-").disabled(textScale <= TextScale.steps.first!)
            Button("Actual Size") { textScale = 1 }.keyboardShortcut("0").disabled(textScale == 1)
            Divider()
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Transcript") { model.findRequest += 1 }.keyboardShortcut("f")
            Button("Search Meetings") { model.searchMeetings() }.keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    lazy var model = AppModel()
    private var waitingToQuit: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Reminders.register()
        MainActor.assumeIsolated { model.start() }
        // Oatcake always opens with its window. macOS remembers a window that was closed when the app
        // quit (it can be quit from the menu bar that way) and would otherwise open with nothing to see.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) { self.model.showWindow() }
                // Settings that couldn't be read: Oatcake is on its defaults, and says so once the window is up.
                if let problem = self.model.takeConfigProblem() {
                    let alert = NSAlert()
                    alert.messageText = "Oatcake’s settings couldn’t be read"
                    alert.informativeText = problem
                    alert.runModal()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        waitingToQuit?.invalidate()
        if model.config.runInBackground {
            // With no windows to switch to, leave only the menu bar item for reopening Oatcake.
            sender.setActivationPolicy(.accessory)
            return false
        }
        guard model.hasWorkInFlight else { return true }

        // Closing a window must not interrupt a recording or work needed to save it.
        waitingToQuit = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.config.runInBackground || NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    self.waitingToQuit?.invalidate()
                } else if !self.model.hasWorkInFlight {
                    self.waitingToQuit?.invalidate()
                    NSApp.terminate(nil)
                }
            }
        }
        return false
    }

    /// Quitting asks first when it would end a recording or interrupt work that's under way.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let question = model.quitQuestion else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = question.title
            alert.informativeText = question.text
            alert.addButton(withTitle: question.ok)
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    /// Opening Oatcake again (including from a pinned Dock icon) brings its window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model.showWindow() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.recording.stopAllRecorders() }
    }

    /// Reminders show even while Oatcake is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // What was pressed, read here: the response itself doesn't cross to the main actor.
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let event = Reminders.event(from: response)
        await MainActor.run { pressed(category: category, action: action, event: event) }
    }

    private func pressed(category: String, action: String, event: CalendarEvent?) {
        // "On a call?": its button starts recording; clicking it opens New recording.
        if category == Reminders.callCategory {
            if action == Reminders.recordAction {
                model.recording.recordCall()
            } else if action == UNNotificationDefaultActionIdentifier {
                model.newRecording(model.recording.noticedCallEvent)
            }
            return
        }
        // "The call seems to have ended": its button keeps the recording going; clicking it shows the call's notes.
        if category == Reminders.stopCategory {
            if action == Reminders.keepAction {
                model.recording.keepRecording()
            } else if action == UNNotificationDefaultActionIdentifier {
                model.showWindow()
                if model.recording.live != nil { model.selection = .live }
            }
            return
        }
        guard let event else {
            // Anything else Oatcake says about a recording: clicking it opens Oatcake.
            if action == UNNotificationDefaultActionIdentifier { model.showWindow() }
            return
        }
        if action == Reminders.startAction {
            model.recording.startFromEvent(event)
        } else if action == UNNotificationDefaultActionIdentifier {
            model.openEvent(event)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // A narrower window can constrain the pane without changing the chosen width.
    @ViewState private var meetingListWidth: CGFloat = 300

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 520)
        } detail: {
            if showsList {
                MeetingListSplit(preferredWidth: $meetingListWidth) {
                    MeetingListView(folder: model.library.tree?.find(model.folder) ?? model.library.tree, root: model.library.tree)
                } detail: {
                    DetailView()
                }
            } else {
                DetailView()
            }
        }
        .overlay(alignment: .bottom) {
            // Only one that says something went wrong takes clicks (to dismiss it).
            if let text = model.toastText { ToastView(text: text, isError: model.toastIsError) { model.dismissToast() }.allowsHitTesting(model.toastIsError) }
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
               presenting: model.confirmation) { confirmation in
            Button(confirmation.cancel, role: .cancel) {}
            Button(confirmation.ok, role: .destructive) {
                // A failure (say, the recording had already stopped) is shown rather than lost.
                Task { do { try await confirmation.action() } catch { model.toast(error.localizedDescription, isError: true) } }
            }
        } message: { confirmation in
            Text(confirmation.text)
        }
    }

    private var showsList: Bool {
        switch model.selection {
        case nil, .meeting, .folder: true
        default: false
        }
    }
}

/// Give the list an explicit width so a detail view's layout cannot reset the divider.
private struct MeetingListSplit<ListContent: View, Detail: View>: View {
    @Binding var preferredWidth: CGFloat
    @ViewBuilder let list: () -> ListContent
    @ViewBuilder let detail: () -> Detail
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 1)
            let minimum = min(220, available)
            let maximum = max(minimum, min(560, available - 420))
            let startingWidth = min(max(preferredWidth, minimum), maximum)
            let width = min(max(startingWidth + dragOffset, minimum), maximum)
            HStack(spacing: 0) {
                list().frame(width: width)
                Divider()
                    .frame(width: 1)
                    .overlay {
                        Color.clear
                            .frame(width: 10)
                            .contentShape(Rectangle())
                            .pointerStyle(.columnResize)
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                                .updating($dragOffset) { drag, offset, _ in offset = drag.translation.width }
                                .onEnded { drag in
                                    let proposed = min(max(startingWidth + drag.translation.width, minimum), maximum)
                                    if proposed != startingWidth { preferredWidth = proposed }
                                })
                    }
                    .zIndex(1)
                    .accessibilityRepresentation {
                        Slider(value: Binding(get: { width }, set: { proposed in
                            let adjusted = min(max(proposed, minimum), maximum)
                            if adjusted != startingWidth { preferredWidth = adjusted }
                        }),
                               in: minimum...max(minimum + 1, maximum)) {
                            Text("Meeting list width")
                        }
                        .accessibilityValue(Text("\(Int(width.rounded())) points"))
                        .disabled(minimum == maximum)
                    }
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The right-hand pane.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.selection {
            case .home:
                HomeView()
            case .meeting(let path, let jump):
                if let node = model.library.tree?.find(path), node.kind == .meeting {
                    MeetingView(node: node, jump: jump)
                        .id(path + (jump.map { $0.nonce.uuidString } ?? ""))
                        .overlay(alignment: .bottom) { AskBar(path: path) }
                } else {
                    blank
                }
            case .todos:
                if model.config.todosEnabled { TodosView() } else { blank }
            case .new(let event, let key):
                NewRecordingView(event: event).id(key)
            case .live:
                if let rec = model.recording.live { LiveView(rec: rec) } else { blank }
            case .job(let id):
                if let rec = model.jobs.pending.first(where: { $0.id == id }) {
                    if rec.state == .processed, !model.jobs.isAnalysing(rec.id) {
                        ReviewView(rec: rec).id(rec.id)
                    } else {
                        ProcessingView(rec: rec).id(rec.id)
                    }
                } else if let rec = model.jobs.unchecked.first(where: { $0.id == id }) {
                    // A meeting saved without checking who's who, having its voices named.
                    ReviewView(rec: rec).id(rec.id)
                } else {
                    blank
                }
            case .folder, nil:
                blank
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An empty folder says so (with Record here) in the middle column; this pane stays blank.
    private var blank: some View {
        Text(listedIn(model.library.tree?.find(model.folder) ?? model.library.tree).isEmpty ? "" : "Select a meeting")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

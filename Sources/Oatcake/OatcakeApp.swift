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
                // Narrow enough to sit beside the call on half a laptop's screen. A toolbar with more
                // than fits puts the rest in its » menu, rather than setting the window's width.
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 880)
        // As in Mail: one toolbar across the columns, the meeting list's folder named over the list.
        .windowToolbarStyle(.unified)
        .commands {
            // View › Hide Sidebar (⌃⌘S), as in Mail.
            SidebarCommands()
            AppCommands(model: delegate.model)
        }

        // Settings is its own window, like a Mac app's Settings. Changes apply as they're made.
        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// What File › Move to Trash does: the meetings selected in the list, or the folder or meeting
/// selected in the sidebar, while that has the keyboard. Anywhere else the command is off, and ⌘⌫
/// keeps its usual meaning (in a text field, say).
struct TrashMeetingsKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var trashMeetings: (() -> Void)? {
        get { self[TrashMeetingsKey.self] }
        set { self[TrashMeetingsKey.self] = newValue }
    }
}

/// The menus: File, Edit's Find and Search, View's tabs and text sizes, Go, Meeting, Recording and Help.
/// What's in them is drawn by views, which see the model change and keep each item's greyed state up to date.
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.trashMeetings) private var trashMeetings
    @AppStorage(TextScale.key) private var textScale = 1.0
    let model: AppModel

    var body: some Commands {
        // The menus are built at launch, before (and whether or not) the window is: this is where
        // the app learns how to open it (and Settings), for the menu bar item, reminders and launch itself.
        let _ = model.openMainWindow = { openWindow(id: "main") }
        let _ = model.openSettingsWindow = { openSettings() }
        CommandGroup(replacing: .newItem) {
            FileItems(model: model, trash: trashMeetings)
        }
        // View › the open meeting's tabs, and the size of reading text: summaries, answers,
        // transcripts, notes and the Markdown editors.
        CommandGroup(before: .toolbar) {
            TabItems(model: model)
            Divider()
            Button("Bigger Text") { textScale = TextScale.bigger(textScale) }.keyboardShortcut("+").disabled(textScale >= TextScale.steps.last!)
            Button("Smaller Text") { textScale = TextScale.smaller(textScale) }.keyboardShortcut("-").disabled(textScale <= TextScale.steps.first!)
            Button("Actual Size") { textScale = 1 }.keyboardShortcut("0").disabled(textScale == 1)
            Divider()
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            FindItems(model: model)
        }
        CommandMenu("Go") { GoItems(model: model) }
        CommandMenu("Meeting") { MeetingMenu(model: model) }
        CommandMenu("Recording") { RecordingItems(model: model) }
        CommandGroup(replacing: .help) {
            Button("Oatcake Help") { NSWorkspace.shared.open(URL(string: "https://github.com/a8cteam51/oatcake/tree/trunk/docs")!) }
        }
    }
}

private struct FileItems: View {
    let model: AppModel
    let trash: (() -> Void)?

    var body: some View {
        // The sidebar's own buttons for these sit in section headers, out of reach of the keyboard and VoiceOver.
        Button("New Folder") { model.wantsNewFolder = true; model.showWindow() }.keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Refresh Calendars") { model.calendar.refresh(force: true) }.keyboardShortcut("r").disabled(!model.calendar.hasCalendars)
        Divider()
        // As in Finder. A menu command, because a key handler on the list didn't answer to ⌘⌫.
        Button("Move to Trash") { trash?() }.keyboardShortcut(.delete, modifiers: .command).disabled(trash == nil)
    }
}

/// View › Summary (⌘1), Transcript, My Notes and Draft, for the open meeting.
private struct TabItems: View {
    let model: AppModel

    var body: some View {
        let open = model.meetingInView
        ForEach(Array(MeetingTab.allCases.enumerated()), id: \.offset) { i, tab in
            Button(tab.menuName) { model.request(.tab(tab)) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .disabled(!(open?.tabs.contains(tab) ?? false))
        }
    }
}

/// Edit › Find in the open meeting's tab, stepping through it, Search Meetings and Ask.
private struct FindItems: View {
    let model: AppModel

    var body: some View {
        let open = model.meetingInView
        Button("Find…") { model.request(.find) }.keyboardShortcut("f").disabled(open == nil)
        Button("Find Next") { model.request(.findNext) }.keyboardShortcut("g").disabled(!(open?.canFindNext ?? false))
        Button("Find Previous") { model.request(.findPrevious) }.keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!(open?.canFindNext ?? false))
        Button("Search Meetings") { model.searchMeetings() }.keyboardShortcut("f", modifiers: [.command, .option])
        // Ask's field is on Home and under a meeting, once there's a meeting to ask about.
        let asking = model.selection == .home || open != nil
        Button("Ask About Your Meetings") { model.showWindow(); model.askRequest += 1 }.keyboardShortcut("l")
            .disabled(!asking || (model.library.tree?.allMeetings.isEmpty ?? true))
    }
}

private struct GoItems: View {
    let model: AppModel

    var body: some View {
        // After following a link: a to-do's, a citation in Ask, a search result.
        Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
        Button("Forward") { model.goForward() }.keyboardShortcut("]").disabled(!model.canGoForward)
        Divider()
        Button("Home") { model.showWindow(); model.selection = .home }
        Button("To-dos") { model.showWindow(); model.selection = .todos }.disabled(!model.config.todosEnabled)
        Button("All Meetings") { model.showWindow(); model.openFolder("") }
    }
}

/// The open meeting's commands, as in its ⋯ menu; greyed out while no meeting is open.
private struct MeetingMenu: View {
    let model: AppModel

    var body: some View {
        let node = model.meetingInView.flatMap { model.library.tree?.find($0.path) }
        MeetingMenuItems(model: model, node: node)
    }
}

private struct RecordingItems: View {
    let model: AppModel

    var body: some View {
        let recording = model.recording
        // As the live screen's Stop: not before audio has arrived (that's Cancel), nor once the recorder has failed.
        let canStop = recording.live != nil && recording.recorderFailure == nil && recording.status.state != .starting
        let call: URL? = {
            if let link = recording.liveCallLink { return link }
            if case .new(let event?) = model.selection { return event.callLink.flatMap(URL.init(string:)) }
            return nil
        }()
        Button("Record a Call…") { model.newRecording() }.keyboardShortcut("n")
        Button("Stop Recording…") { model.stopFromMenuBar() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!canStop)
        Divider()
        Button("Join Call") { if let call { NSWorkspace.shared.open(call) } }.disabled(call == nil)
        Button("Show Live Notes") { model.showWindow(); model.selection = .live }.disabled(recording.live == nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    lazy var model = AppModel()
    /// Looks every couple of seconds for the end of the work that kept Oatcake open with no window.
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

    /// With Settings › General › Run in the background on, closing the last window leaves Oatcake in
    /// the menu bar, out of the Dock, still checking for calls; showWindow brings the Dock icon back.
    /// With it off, closing the last window quits, but not under work that's still going (a call
    /// being recorded or analysed, a summary being written, an import, a model on its way down):
    /// Oatcake stays until that has ended, then quits. Opening a window again calls that off.
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
            // Typing from the last moments is written first, so the question knows what couldn't be.
            model.saveEdits()
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
        MainActor.assumeIsolated {
            model.saveEdits()
            model.recording.stopAllRecorders()
        }
    }

    /// Reminders show even while Oatcake is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // What was pressed, read here: the response itself doesn't cross to the main actor.
        let request = response.notification.request
        let category = request.content.categoryIdentifier
        let action = response.actionIdentifier
        let id = request.identifier
        await MainActor.run { pressed(category: category, action: action, id: id) }
    }

    private func pressed(category: String, action: String, id: String) {
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
        // "Ready to check who's who": clicking it opens that recording's Who's who, if it's still waiting.
        if let recording = Reminders.recording(readyToCheck: id) {
            guard action == UNNotificationDefaultActionIdentifier else { return }
            model.showWindow()
            if model.jobs.pending.contains(where: { $0.id == recording }) { model.selection = .job(recording) }
            return
        }
        guard category == Reminders.category else {
            // Anything else Oatcake says about a recording: clicking it opens Oatcake.
            if action == UNNotificationDefaultActionIdentifier { model.showWindow() }
            return
        }
        guard let event = currentEvent(forReminder: id, in: model.calendar.events) else {
            // The invite may have moved, been ignored or lost its last connected calendar.
            model.showWindow()
            if action == Reminders.startAction {
                model.toast("That call isn’t on your calendar any more, so nothing was opened or recorded.", isError: true)
            }
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
    /// The new title being typed for a meeting being renamed.
    @ViewState private var title = ""
    /// Renaming is being asked again after it failed: the title stays as typed.
    @ViewState private var keepTitle = false
    /// The sidebar is showing, in either layout: hidden in one, it stays hidden in the other.
    @AppStorage("sidebarShown") private var sidebarShown = true

    /// A folder or All meetings chosen, or a meeting open: the meeting list is beside it.
    private var listShown: Bool {
        switch model.selection {
        case .folder, .meeting: true
        default: false
        }
    }

    var body: some View {
        @Bindable var model = model
        // Laid out as Mail is: folders, the meetings in the one chosen, and the meeting. Home, To-dos,
        // a recording and Who's who have nothing to do with the meeting list, so they sit beside the
        // sidebar alone. A three-column split view can't hide only its middle column, so the window
        // has a three-column one while the list shows and a two-column one otherwise. (The list and the
        // meeting split inside a two-column one's right-hand pane would share out every change in the
        // window's width, and couldn't be told the list's width.)
        //
        // Both split views save their columns' frames under the one name, so each would find the
        // other's there. A split view with another number of columns was seen to discard them, but
        // nothing promises it, so they're removed before either split view is made (at launch, and
        // each time the list comes or goes) and each column starts at the width KeepsWidth kept.
        let _ = UserDefaults.standard.removeObject(forKey: savedColumnFrames)
        let sidebarWidth = KeepsWidth(key: "sidebarWidth", range: 200...520, ideal: 260, shown: sidebarShown)
        Group {
            if listShown {
                NavigationSplitView(columnVisibility: sidebar(hiddenAs: .doubleColumn)) {
                    SidebarView().modifier(sidebarWidth)
                } content: {
                    MeetingListView().modifier(KeepsWidth(key: "meetingListWidth", range: 220...560, ideal: 300))
                } detail: {
                    DetailView()
                }
            } else {
                NavigationSplitView(columnVisibility: sidebar(hiddenAs: .detailOnly)) {
                    SidebarView().modifier(sidebarWidth)
                } detail: {
                    DetailView()
                }
            }
        }
        // Search is modal: while it's open, the window behind it can't be worked through accessibility either.
        .accessibilityHidden(model.searching)
        .overlay { if model.searching { SearchOverlay() } }
        .overlay(alignment: .bottom) {
            // Only one that says something went wrong takes clicks (to dismiss it).
            if let text = model.toastText { ToastView(text: text, isError: model.toastIsError) { model.dismissToast() }.allowsHitTesting(model.toastIsError) }
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0, let id = model.confirmation?.id { model.endConfirmation(id) } }),
               presenting: model.confirmation) { confirmation in
            Button(confirmation.cancel, role: .cancel) {}
            Button(confirmation.ok, role: confirmation.destructive ? .destructive : nil) {
                // A failure (say, the recording had already stopped) is shown rather than lost.
                Task { do { try await confirmation.action() } catch { model.toast(error.localizedDescription, isError: true) } }
            }
            .keyboardShortcut(confirmation.destructive ? nil : .defaultAction)
        } message: { confirmation in
            Text(confirmation.text)
        }
        // Rename… from any of a meeting's menus.
        .onChange(of: model.renaming) {
            if let node = model.renaming, !keepTitle { title = meetingTitle(node) }
            keepTitle = false
        }
        .alert("Rename meeting", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Rename") {
                guard let node = model.renaming, !model.library.retitle(node.path, to: title) else { return }
                askAgain { keepTitle = true; model.renaming = node }
            }
            .disabled(title.trimmed.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes the meeting’s title and its folder’s name.")
        }
    }

    /// The sidebar shown or hidden. The two layouts name a hidden sidebar differently: with the list,
    /// the two columns left are the list and the meeting; without it, only the screen is left.
    private func sidebar(hiddenAs hidden: NavigationSplitViewVisibility) -> Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarShown ? .all : hidden }, set: { sidebarShown = $0 != hidden && $0 != .detailOnly })
    }
}

/// Where SwiftUI saves the main window's split view columns: the window's id, then the kind of split
/// view. The two-column and the three-column split views share it.
private let savedColumnFrames = "NSSplitView Subview Frames main, SidebarNavigationSplitView"

/// A column that starts at the width it last had, in place of the split view's own saved frames
/// (see ContentView). A width is kept once it has held for half a second while the column shows and
/// is one it can be dragged to: not one passed through as the sidebar slides away, or as the split
/// view is first laid out. The column's width has to be the last modifier: under the others, the
/// split view ignored it and opened the sidebar at 144 points, narrower than its minimum.
private struct KeepsWidth: ViewModifier {
    let key: String
    let range: ClosedRange<CGFloat>
    let ideal: CGFloat
    var shown = true
    @ViewState private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let saved = CGFloat(UserDefaults.standard.double(forKey: key))
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: [width, shown ? 1 : 0]) {
                guard shown, range.contains(width), (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
                UserDefaults.standard.set(Double(width), forKey: key)
            }
            .navigationSplitViewColumnWidth(min: range.lowerBound, ideal: range.contains(saved) ? saved : ideal, max: range.upperBound)
    }
}

/// The right-hand pane. A screen without the meeting list beside it names itself in the window's
/// title; with the list, the title is the list's folder.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    private var hasMeetings: Bool { !(model.library.tree?.allMeetings.isEmpty ?? true) }

    var body: some View {
        Group {
            switch model.selection {
            case .home:
                HomeView()
                    .navigationTitle("Home")
                    // Nothing to ask about until something is saved.
                    .safeAreaPadding(.bottom, hasMeetings ? 58 : 0)
                    .overlay(alignment: .bottom) { if hasMeetings { AskBar(path: nil) } }
            case .meeting(let path, let jump):
                if let node = model.library.tree?.find(path), node.kind == .meeting {
                    MeetingView(node: node, jump: jump)
                        .id(path + (jump.map { $0.nonce.uuidString } ?? ""))
                        .overlay(alignment: .bottom) { AskBar(path: path) }
                } else {
                    blank
                }
            case .todos:
                if model.config.todosEnabled { TodosView().navigationTitle("To-dos") } else { blank }
            case .new(let event):
                // Made again only for another event: choosing the same one again keeps what's been typed.
                NewRecordingView(event: event).id(event?.id)
                    .navigationTitle("Record a call")
            case .live:
                if let rec = model.recording.live { LiveView(rec: rec).navigationTitle(rec.title) } else { blank }
            case .job(let id):
                Group {
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
                }
                .navigationTitle("Who’s who")
                // Its toolbar starts with what it is and which call, so the title isn't said twice there.
                .toolbar(removing: .title)
            case .folder, nil:
                blank
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An empty folder has its name here, with Record here, rather than leaving most of the window
    /// blank. The middle column then only says the folder is empty, so the button isn't there twice.
    private var blank: some View {
        let folder = model.library.tree.map { $0.find(model.folder) ?? $0 }
        let everything = folder?.path.isEmpty ?? true
        return ZStack {
            if let folder, newestIn(folder, 1).isEmpty {
                VStack(spacing: 14) {
                    PageTitle(text: everything ? "All meetings" : baseName(folder.path))
                    Button { model.newRecording() } label: { Label(everything ? "Record a call" : "Record here", systemImage: "circle.fill") }
                }
            } else if folder != nil {
                Text("Select a meeting").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { EmptyPaneToolbar() }
    }
}

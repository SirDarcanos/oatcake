import Foundation
import OatcakeCore
import UserNotifications

/// Call reminders through Notification Center, with one button.
enum Reminders {
    static let category = "call-reminder"
    static let startAction = "start"

    static let callCategory = "call-noticed"
    static let recordAction = "record"

    static let stopCategory = "call-ending"
    static let keepAction = "keep"

    /// When Oatcake last posted a notification with a sound. The sound comes out of the Mac like any
    /// other, so a recording in progress hears it as call audio (see RecordingController.callAudioQuiet).
    @MainActor private(set) static var lastSound = Date.distantPast

    static func register() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: startAction, title: "Join and start recording", options: [.foreground])
        let record = UNNotificationAction(identifier: recordAction, title: "Start recording", options: [.foreground])
        // Not in the foreground: keeping a recording going shouldn't take you away from the call.
        let keep = UNNotificationAction(identifier: keepAction, title: "Keep recording", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [start], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: callCategory, actions: [record], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: stopCategory, actions: [keep], intentIdentifiers: [])])
    }

    /// Something about the recording you'd want to know while looking at the call, not at Oatcake.
    /// One with the same `id` replaces the one before it.
    @MainActor static func say(_ title: String, _ body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        post(content, id: id)
    }

    /// The call seems to be over: recording stops in half a minute unless Keep recording is chosen.
    @MainActor static func warnOfStop() {
        let content = UNMutableNotificationContent()
        content.title = "The call seems to have ended"
        content.body = "Recording stops in 30 seconds."
        content.categoryIdentifier = stopCategory
        content.sound = .default
        post(content, id: stopCategory)
    }

    static func withdrawStopWarning() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [stopCategory])
        center.removePendingNotificationRequests(withIdentifiers: [stopCategory])
    }

    /// Whether Oatcake may show notifications, asking the first time.
    private static func allowed() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
    }

    @MainActor private static func post(_ content: sending UNMutableNotificationContent, id: String) {
        if content.sound != nil { lastSound = Date() }
        Task {
            guard await allowed() else { return }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// A calling app has started using the microphone and nothing is being recorded.
    @MainActor static func offerRecording(app: String, event: CalendarEvent?) {
        let content = UNMutableNotificationContent()
        content.title = "On a call?"
        content.body = "\(app) is using your microphone\(event.map { " (\($0.title))" } ?? ""). Oatcake isn’t recording."
        content.categoryIdentifier = callCategory
        content.sound = .default
        post(content, id: "call-noticed")
    }

    /// A recording stopped by itself because its call ended.
    @MainActor static func stopped(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The call ended, so Oatcake stopped recording “\(title)” and is transcribing it."
        post(content, id: "call-ended")
    }

    /// A call has been processed and waits in Who's who. No sound: it can wait until you're back.
    @MainActor static func readyToCheck(_ title: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = "Ready to check who’s who"
        content.body = "“\(title)” is waiting under Needs review."
        post(content, id: readyPrefix + id)
    }

    /// The recording has been saved or discarded: its notification has nothing left to say.
    static func withdrawReadyToCheck(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [readyPrefix + id])
    }

    /// The recording a "ready to check who's who" notification is about, from the notification's identifier.
    static func recording(readyToCheck notification: String) -> String? {
        notification.hasPrefix(readyPrefix) ? String(notification.dropFirst(readyPrefix.count)) : nil
    }

    private static let readyPrefix = "review-"

    @MainActor static func show(_ event: CalendarEvent) {
        lastSound = Date()
        Task {
            guard await allowed() else { return }
            let minutes = Int((event.startDate.timeIntervalSinceNow / 60).rounded())
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = [minutes > 0 ? "In \(longDuration(Double(minutes) * 60))" : "Starting now", "\(timeOfDay(event.startDate))–\(timeOfDay(event.endDate))",
                            event.callLink.flatMap(callApp)].compactMap { $0 }.joined(separator: " · ")
            content.categoryIdentifier = category
            // The request ID identifies the occurrence; Notification Center doesn’t need the invite.
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }

}

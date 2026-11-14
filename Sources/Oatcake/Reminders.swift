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

    static func register() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: startAction, title: "Open call and start note taking", options: [.foreground])
        let record = UNNotificationAction(identifier: recordAction, title: "Start recording", options: [.foreground])
        // Not in the foreground: keeping a recording going shouldn't take you away from the call.
        let keep = UNNotificationAction(identifier: keepAction, title: "Keep recording", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [start], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: callCategory, actions: [record], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: stopCategory, actions: [keep], intentIdentifiers: [])])
    }

    /// Something about the recording you'd want to know while looking at the call, not at Oatcake.
    /// One with the same `id` replaces the one before it.
    static func say(_ title: String, _ body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        post(content, id: id)
    }

    /// The call seems to be over: recording stops in half a minute unless Keep recording is chosen.
    static func warnOfStop() {
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

    private static func post(_ content: sending UNMutableNotificationContent, id: String) {
        Task {
            guard await allowed() else { return }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// A calling app has started using the microphone and nothing is being recorded.
    static func offerRecording(app: String, event: CalendarEvent?) {
        let content = UNMutableNotificationContent()
        content.title = "On a call?"
        content.body = "\(app) is using your microphone\(event.map { " (\($0.title))" } ?? ""). Oatcake isn’t recording."
        content.categoryIdentifier = callCategory
        content.sound = .default
        post(content, id: "call-noticed")
    }

    /// A recording stopped by itself because its call ended.
    static func stopped(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The call ended, so Oatcake stopped recording “\(title)” and is transcribing it."
        post(content, id: "call-ended")
    }

    static func show(_ event: CalendarEvent) {
        Task {
            guard await allowed() else { return }
            let minutes = Int((event.startDate.timeIntervalSinceNow / 60).rounded())
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = [minutes > 0 ? "In \(minutes) min" : "Starting now", "\(hhmm(event.startDate))–\(hhmm(event.endDate))",
                            event.callLink.flatMap(callApp)].compactMap { $0 }.joined(separator: " · ")
            content.categoryIdentifier = category
            content.userInfo = ["event": (try? encodeJSON(event)) ?? ""]
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }

    static func event(from response: UNNotificationResponse) -> CalendarEvent? {
        (response.notification.request.content.userInfo["event"] as? String)
            .flatMap { try? JSONDecoder().decode(CalendarEvent.self, from: Data($0.utf8)) }
    }
}

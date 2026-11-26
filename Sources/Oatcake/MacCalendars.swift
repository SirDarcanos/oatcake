// This Mac's own calendars (the ones in its Calendar app), read through EventKit for the calendars
// added with Settings › Calendars › Add from this Mac…, which is the only place access is asked for.
// What's read becomes the same events an iCal feed gives (OatcakeCore's MacCalendar.swift).
import EventKit
import Foundation
import OatcakeCore

@MainActor
final class MacCalendars {
    enum Access { case notAsked, allowed, refused, restricted }

    /// Whether Oatcake may read this Mac's calendars. Asking doesn't show anything.
    static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notAsked
        case .fullAccess: .allowed
        case .restricted: .restricted
        // Denied, or allowed only to add events, which can't be read.
        default: .refused
        }
    }

    /// One of this Mac's calendars, to choose from.
    struct Choice: Identifiable, Hashable {
        let id: String
        let title: String
        let account: String
    }

    /// Called when anything in the Mac's calendars changes, or access to them does.
    var changed: () -> Void = {}
    private var store: EKEventStore?
    private var observer: NSObjectProtocol?

    /// Made the first time it's needed, so a Mac with no calendar added from it is never touched.
    private func opened() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        // Also posted when access is given or taken away in System Settings.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        self.store = store
        return store
    }

    /// macOS asks the first time (its own dialog); afterwards this only says whether it's allowed.
    func requestAccess() async -> Bool {
        guard Self.access == .notAsked else { return Self.access == .allowed }
        let store = opened()
        // The answer comes on a queue of EventKit's own, so the closure mustn't belong to the main actor.
        return await withCheckedContinuation { answered in
            store.requestFullAccessToEvents { @Sendable granted, _ in answered.resume(returning: granted) }
        }
    }

    /// This Mac's calendars, by account.
    func choices() -> [Choice] {
        guard Self.access == .allowed else { return [] }
        return opened().calendars(for: .event)
            .map { Choice(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account.lowercased(), $0.title.lowercased()) < ($1.account.lowercased(), $1.title.lowercased()) }
    }

    /// The events on one of this Mac's calendars that a calendar's cache keeps (calendarWindow).
    func events(in calendarID: String, around now: Date) -> Result<[MacEvent], OatcakeError> {
        // Opened even when it can't be read: it's what says when that changes.
        let store = opened()
        switch Self.access {
        case .allowed: break
        case .restricted: return .failure(OatcakeError("this Mac doesn’t let apps read its calendars"))
        case .notAsked, .refused: return .failure(OatcakeError("Oatcake isn’t allowed to read this Mac’s calendars"))
        }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            return .failure(OatcakeError("this calendar isn’t on this Mac any more"))
        }
        let window = calendarWindow(around: now)
        let found = store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar]))
        return .success(found.compactMap { event in
            guard let uid = event.calendarItemExternalIdentifier ?? event.eventIdentifier else { return nil }
            let people = ([event.organizer].compactMap { $0 } + (event.attendees ?? [])).map { person in
                MacEvent.Person(name: person.name, url: person.url.absoluteString, declined: person.participantStatus == .declined,
                                resource: [.room, .resource].contains(person.participantType), isYou: person.isCurrentUser)
            }
            return MacEvent(uid: uid, title: event.title, start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                            recurring: event.hasRecurrenceRules || event.isDetached, cancelled: event.status == .canceled,
                            url: event.url?.absoluteString, location: event.location, notes: event.notes, people: people)
        })
    }
}

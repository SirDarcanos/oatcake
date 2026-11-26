// Calendar feeds are fetched and cached independently, and this Mac's own calendars read from its
// store (MacCalendars); every consumer gets the same merged events.
import Foundation
import OatcakeCore
import SwiftUI

@MainActor @Observable
final class CalendarController {
    var app = AppServices()
    var changed: @MainActor () -> Void = {}
    /// The calendar event being recorded now, if any: it isn't reminded of.
    var recordingEvent: @MainActor () -> String? = { nil }
    private var config: Config { app.config() }

    struct Label: Identifiable {
        let id: UUID
        let name: String
        let colour: SwatchColour
        /// One of this Mac's calendars, which has no address.
        var onThisMac = false
    }

    private var sources: [CalendarSource] = []
    private var caches = CalendarFeedCaches()
    private var merged = MergedCalendar([])
    private(set) var settingsProblem: String?
    private var fetches: [UUID: Task<Void, Never>] = [:]
    private var reminded = SentReminders()
    private var timers: [Timer] = []
    private let mac = MacCalendars()
    /// Whether this Mac's calendars can be read, as last looked at.
    private(set) var macAccess = MacCalendars.access
    var now = Date()

    var calendars: [Label] { sources.map { Label(id: $0.id, name: $0.name, colour: $0.colour, onThisMac: $0.macCalendarID != nil) } }
    var hasCalendars: Bool { sources.contains(where: \.isConnected) }
    var hasMacCalendars: Bool { sources.contains { $0.macCalendarID != nil } }
    var fetching: Bool { !fetches.isEmpty }
    var hasUpdated: Bool { caches.values.contains { $0.updatedAt != nil } }
    var hasFailures: Bool { caches.values.contains { $0.error != nil } }
    var nextColour: SwatchColour { CalendarSource.nextColour(sources) }
    var rawEvents: [CalendarEvent] { merged.events }
    var events: [CalendarEvent] {
        let config = config
        return rawEvents.filter { !ignoredEvent($0.title, config.ignoredEvents) && !isIgnored($0, config.ignoredCalendarEvents) }
    }

    func sourceIDs(for event: CalendarEvent) -> [UUID] { merged.sourcesByEvent[event.id] ?? [] }

    func labels(for event: CalendarEvent) -> [Label] { labels(for: sourceIDs(for: event)) }

    func labels(for ids: [UUID]?) -> [Label] {
        guard let ids, !ids.isEmpty else { return [] }
        return calendars.filter { ids.contains($0.id) }
    }

    func status(for id: UUID) -> String {
        guard let source = sources.first(where: { $0.id == id }) else { return "Not fetched yet" }
        guard source.isConnected else { return "No address saved. Choose Edit… and paste it again." }
        let fetchID = source.fetchID
        if fetches[fetchID] != nil { return "Updating…" }
        if let failure = caches[fetchID]?.failure { return failure }
        // Read again whenever it changes, so when it was last read says nothing.
        if source.macCalendarID != nil { return "On this Mac" }
        if let updated = parseISO(caches[fetchID]?.updatedAt) { return "Updated \(weekdayName(updated, short: true)) at \(timeOfDay(updated))" }
        return "Not fetched yet"
    }

    func start() {
        reminded = SentReminders.load()
        mac.changed = { [weak self] in self?.readMacCalendars(force: true) }
        do {
            sources = try CalendarSource.load()
            caches.setSources(sources)
            merge()
        } catch {
            settingsProblem = "Oatcake couldn’t read the saved calendar settings. Your private addresses haven’t been changed."
        }
        refresh()
        checkReminders()
        // Each minute, so a fetch that failed is tried again on time: refresh() fetches only what's stale.
        timers.append(Timer.common(every: 60) { _ in Task { @MainActor in self.refresh() } })
    }

    func refresh(force: Bool = false) {
        for source in sources where !source.address.isEmpty {
            let id = source.fetchID
            guard fetches[id] == nil else { continue }
            let previous = caches[id] ?? CalendarCache()
            guard force || previous.isStale() else { continue }
            fetches[id] = Task { [weak self] in
                let cache = await fetchCalendar(source.address, previous: previous)
                guard let self, !Task.isCancelled else { return }
                self.fetches[id] = nil
                if self.caches.receive(cache, from: id) { self.merge() }
            }
        }
        readMacCalendars(force: force)
    }

    /// This Mac's calendars, on the feeds' schedule and whenever the Mac's store changes. Read on the
    /// main actor, as EventKit's store is: it's this Mac's own database, two weeks of it.
    private func readMacCalendars(force: Bool) {
        macAccess = MacCalendars.access
        var received = false
        for source in sources {
            guard let calendarID = source.macCalendarID else { continue }
            let previous = caches[source.fetchID] ?? CalendarCache()
            guard force || previous.isStale() else { continue }
            let cache = macCalendarCache(mac.events(in: calendarID, around: Date()), previous: previous)
            received = caches.receive(cache, from: source.fetchID) || received
        }
        if received { merge() }
    }

    /// Asks for access to this Mac's calendars the first time (macOS's own dialog); true once it's given.
    func allowMacCalendars() async -> Bool {
        let allowed = await mac.requestAccess()
        macAccess = MacCalendars.access
        if allowed { readMacCalendars(force: true) }
        return allowed
    }

    /// This Mac's calendars that haven't been added yet.
    func macCalendarChoices() -> [MacCalendars.Choice] {
        let added = Set(sources.compactMap(\.macCalendarID))
        return mac.choices().filter { !added.contains($0.id) }
    }

    func addFromThisMac(_ chosen: [MacCalendars.Choice]) throws {
        var updated = sources
        for choice in chosen {
            updated.append(CalendarSource(name: choice.title, colour: CalendarSource.nextColour(updated), macCalendarID: choice.id))
        }
        try apply(updated)
    }

    func save(id: UUID?, name: String, colour: SwatchColour, address: String) throws {
        if let settingsProblem { throw OatcakeError(settingsProblem) }
        let name = name.trimmed
        guard !name.isEmpty else { throw OatcakeError("Give this calendar a name.") }
        var updated = sources
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
            updated[index].name = name
            updated[index].colour = colour
            if !address.trimmed.isEmpty {
                try updated[index].replaceAddress(CalendarSource.validatedAddress(address))
            }
        } else {
            guard !address.trimmed.isEmpty else { throw OatcakeError("Paste the calendar’s private iCal address.") }
            updated.append(CalendarSource(name: name, colour: colour, address: try CalendarSource.validatedAddress(address)))
        }
        try apply(updated)
    }

    func remove(_ id: UUID) throws {
        try apply(sources.filter { $0.id != id })
    }

    private func apply(_ updated: [CalendarSource]) throws {
        if let settingsProblem { throw OatcakeError(settingsProblem) }
        do { try CalendarSource.save(updated) }
        catch { throw OatcakeError("Oatcake couldn’t save the calendar settings. Nothing was changed.") }
        let active = Set(updated.map(\.fetchID))
        for source in sources where !active.contains(source.fetchID) {
            fetches.removeValue(forKey: source.fetchID)?.cancel()
        }
        caches.setSources(updated)
        sources = updated
        merge()
        refresh()
    }

    private func merge() {
        merged = MergedCalendar(sources.map { ($0.id, caches[$0.fetchID]?.events ?? []) })
        changed()
    }

    // Call reminders: before each call, as many minutes before as Settings › Calendars says (once
    // for each), a notification whose button opens the call and starts recording it. Clicking the
    // notification itself opens New recording for the event.
    func checkReminders() {
        guard config.callReminders else { return }
        let due = reminded.due(events, minutes: config.reminderMinutes, at: Date(), recording: recordingEvent())
        guard !due.isEmpty else { return }
        try? reminded.save()
        due.forEach(Reminders.show)
    }

    func currentEvent(unless recorded: Set<String> = []) -> CalendarEvent? {
        eventHappening(events, at: Date(), unless: recorded)
    }
}

struct CalendarBadges: View {
    let calendars: [CalendarController.Label]
    var describe = false

    var body: some View {
        if !calendars.isEmpty {
            if describe {
                let names = calendars.map(\.name).joined(separator: ", ")
                dots.accessibilityElement(children: .ignore).accessibilityLabel(names).help(names)
            } else {
                dots.accessibilityHidden(true)
            }
        }
    }

    private var dots: some View {
        let diameter: CGFloat = 7
        let step: CGFloat = 5
        let borderWidth: CGFloat = 1.5
        return Canvas { context, _ in
            for (index, calendar) in calendars.enumerated() {
                let bounds = CGRect(x: CGFloat(index) * step, y: 0, width: diameter, height: diameter)
                var dot = Path(ellipseIn: bounds)
                if index + 1 < calendars.count {
                    // Let the row’s actual background show as a thin border around the dot in front.
                    let border = bounds.offsetBy(dx: step, dy: 0).insetBy(dx: -borderWidth, dy: -borderWidth)
                    dot = dot.subtracting(Path(ellipseIn: border))
                }
                context.fill(dot, with: .color(calendar.colour.swatch))
            }
        }
        .frame(width: diameter + CGFloat(calendars.count - 1) * step, height: diameter)
        .fixedSize()
    }
}

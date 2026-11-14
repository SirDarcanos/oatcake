// The calendar: its events, fetched from its private address and kept between launches, and the
// reminders before each call.

import Foundation
import OatcakeCore
import SwiftUI

@MainActor @Observable
final class CalendarController {
    /// What this part asks of the app around it.
    var app = AppServices()
    /// The events have changed: the menu bar's next call may have.
    var changed: @MainActor () -> Void = {}
    private var config: Config { app.config() }

    /// nil when no calendar address is set.
    var cache: CalendarCache?
    /// The time, moved on every half minute: what Upcoming's countdowns are worked out from.
    var now = Date()
    var fetching = false
    private var calendarFetch: (url: String, task: Task<CalendarCache, Never>)?
    private var calendarUrlFetched = ""
    private var reminded = Set<String>()
    private var timers: [Timer] = []

    func start() {
        // An address set in an earlier session counts as already fetched, so this only fetches if stale.
        calendarUrlFetched = calendarAddress
        refresh()
        checkReminders()
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Task { @MainActor in self.refresh() } })
    }

    /// The calendar's private iCal address. "" = no calendar.
    private var calendarAddress: String { Secrets.get(.calendar).trimmed }

    /// Fetched at most once an hour (checked every 5 minutes, so a Mac that slept catches up),
    /// straight away when its address changes, and whenever the refresh button is pressed.
    func refresh(force: Bool = false) {
        let url = calendarAddress
        guard !url.isEmpty else {
            cache = nil
            return
        }
        // Joins a fetch already running for this address.
        if calendarFetch?.url == url { return }
        let cached = CalendarCache.load()
        if cache == nil { cache = cached }
        if !force, url == calendarUrlFetched, !cached.isStale() { return }
        fetching = true
        let task = Task { await fetchCalendar(url) }
        calendarFetch = (url, task)
        Task {
            let cache = await task.value
            // The address changed meanwhile: an older fetch's result is thrown away.
            guard calendarFetch?.url == url else { return }
            calendarFetch = nil
            fetching = false
            calendarUrlFetched = url
            try? cache.save()
            self.cache = cache
            changed()
        }
    }

    /// A new (or no) calendar address: forget the old one's events and fetch the new one.
    func addressChanged() {
        calendarFetch = nil
        fetching = false
        calendarUrlFetched = ""
        try? FileManager.default.removeItem(at: Paths.calendar)
        cache = nil
        if !calendarAddress.isEmpty { refresh(force: true) }
    }

    // Call reminders: 5 minutes before each call, a notification whose button opens the call and
    // starts recording it. Clicking the notification itself opens New recording for the event.
    func checkReminders() {
        guard config.callReminders, let calendar = cache else { return }
        let now = Date()
        for event in calendar.events where !event.allDay && !reminded.contains(event.id) {
            let until = event.startDate.timeIntervalSince(now)
            // In the five minutes before it starts (or the first minute after, if the Mac was asleep).
            guard until <= 300, until >= -60 else { continue }
            reminded.insert(event.id)
            Reminders.show(event)
        }
    }

    /// The calendar event happening now (or starting within ten minutes), if any.
    var currentEvent: CalendarEvent? {
        let now = Date()
        return cache?.events.first { !$0.allDay && $0.startDate.addingTimeInterval(-600) <= now && $0.endDate > now }
    }
}

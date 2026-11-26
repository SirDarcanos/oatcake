import Foundation
@testable import OatcakeCore
import Testing

/// Dates, times and lengths of time as the windows show them, and when a meeting happened.
@Suite struct DatesTests {
    let thursday = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 16, minute: 30))!
    let british = Locale(identifier: "en_GB")
    let american = Locale(identifier: "en_US")

    /// A region with its clock set the other way in System Settings.
    private func region(_ id: String, twelveHour: Bool) -> Locale {
        var components = Locale.Components(identifier: id)
        components.hourCycle = twelveHour ? .oneToTwelve : .zeroToTwentyThree
        return Locale(components: components)
    }

    /// The Mac's region decides the order of day and month; the words are checked loosely, as macOS's
    /// own formats can change their punctuation from one release to the next.
    @Test func writesDatesInTheMacsRegion() {
        #expect(longDay(thursday, locale: british).contains("Thursday") && longDay(thursday, locale: british).contains("29 October 2026"))
        #expect(longDay(thursday, locale: american).contains("October 29"))
        #expect(shortDay(thursday, now: thursday, locale: british).contains("Thu") && shortDay(thursday, now: thursday, locale: british).contains("29 Oct"))
        #expect(shortDay(thursday, now: thursday, locale: american).contains("Oct 29"))
        #expect(compactDate(thursday, now: thursday, locale: british) == "29 Oct")
        #expect(weekdayName(thursday, locale: british) == "Thursday")
        #expect(weekdayName(thursday, short: true, locale: british) == "Thu")
    }

    /// The year only when it isn't this one.
    @Test func addsTheYearForAnotherYear() {
        let nextYear = gregorian.date(byAdding: .year, value: 1, to: thursday)!
        #expect(!compactDate(thursday, now: thursday, locale: british).contains("2026"))
        #expect(compactDate(thursday, now: nextYear, locale: british).contains("29 Oct 2026"))
        #expect(shortDay(thursday, now: nextYear, locale: british).contains("2026"))
    }

    /// The Mac's 12- or 24-hour setting, whatever its region usually does.
    @Test func followsTheMacsClock() {
        #expect(timeOfDay(thursday, locale: british) == "16:30")
        #expect(timeOfDay(thursday, locale: region("en_GB", twelveHour: true)).contains("4:30"))
        #expect(timeOfDay(thursday, locale: american).contains("4:30"))
        #expect(timeOfDay(thursday, locale: region("en_US", twelveHour: false)) == "16:30")
        #expect(dayAndTime(thursday, locale: british) == "Thu 16:30")
        #expect(dateAndTime(thursday, locale: british).contains("29 Oct") && dateAndTime(thursday, locale: british).contains("16:30"))
    }

    /// Seconds under a minute, then whole minutes, rounded down.
    @Test func writesLengthsOfTimeShortAndLong() {
        #expect(shortDuration(45) == "45s")
        #expect(shortDuration(12 * 60) == "12m")
        #expect(shortDuration(65 * 60) == "1h 5m")
        #expect(shortDuration(120 * 60) == "2h")
        #expect(longDuration(1) == "1 second")
        #expect(longDuration(47.8) == "47 seconds")
        #expect(longDuration(60) == "1 minute")
        #expect(longDuration(90) == "1 minute")
        #expect(longDuration(32 * 60 + 20) == "32 minutes")
        #expect(longDuration(65 * 60) == "1 hour 5 minutes")
        #expect(longDuration(2 * 3600) == "2 hours")
        #expect(longDuration(-5) == "0 seconds")
    }

    /// meeting.json's start when it has one, or else the folder name's date; newest first, then by name.
    @Test func findsWhenAMeetingHappened() {
        let saved = TreeNode(name: "2026-10-02 1400 Leads sync", path: "Team/2026-10-02 1400 Leads sync", kind: .meeting, startedAt: thursday)
        let named = TreeNode(name: "2026-10-02 1400 Leads sync", path: "Team/2026-10-02 1400 Leads sync", kind: .meeting)
        let undated = TreeNode(name: "Notes from John Doe", path: "Team/Notes from John Doe", kind: .meeting)
        #expect(meetingDate(saved) == thursday)
        #expect(meetingDate(named) == gregorian.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 0)))
        #expect(meetingDate(undated) == nil)
        let sameTime = TreeNode(name: "2026-10-02 1400 Budget", path: "Team/2026-10-02 1400 Budget", kind: .meeting)
        #expect([undated, sameTime, named, saved].sorted(by: newestFirst).map(\.name)
            == ["2026-10-02 1400 Leads sync", "2026-10-02 1400 Leads sync", "2026-10-02 1400 Budget", "Notes from John Doe"])
    }
}

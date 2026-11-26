import Foundation
import Security
@testable import OatcakeCore
import Testing

struct CalendarSourceTests {
    @Test func sharedSwatchesKeepPeopleIndicesAndReadTestBuildColours() throws {
        #expect(SwatchColour.allCases.map(\.hue) == [265, 25, 160, 330, 200, 60, 295, 130, 230, 0, 95, 180])
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SwatchColour.self, from: Data("\"pink\"".utf8)) == .raspberry)
        #expect(try decoder.decode(SwatchColour.self, from: Data("\"brown\"".utf8)) == .mustard)
        // A colour this version doesn't know still loads, as the first one.
        #expect(try decoder.decode(SwatchColour.self, from: Data("\"chartreuse\"".utf8)) == .indigo)
        for colour in SwatchColour.allCases {
            #expect(try decoder.decode(SwatchColour.self, from: JSONEncoder().encode(colour)) == colour)
        }
    }

    @Test func migrateAndChangePrivateCalendars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.json")
        try Secrets.set(.calendar, "https://example.com/private/first.ics", file: file)
        var calendars = try CalendarSource.load(from: file, inheritedAddress: "https://example.com/environment.ics")
        let first = try #require(calendars.first)
        #expect(calendars.count == 1)
        #expect(first.address == "https://example.com/private/first.ics")
        #expect(first.cacheFile(in: root).lastPathComponent == "calendar.json")
        calendars[0].name = "Work"
        calendars.append(CalendarSource(name: "Personal", colour: CalendarSource.nextColour(calendars),
                                        address: try CalendarSource.validatedAddress(" webcal://example.com/private/second.ics ")))
        #expect(calendars[0].colour != calendars[1].colour)
        #expect(calendars[1].address.hasPrefix("https://"))
        #expect(calendars[1].cacheFile(in: root) != first.cacheFile(in: root))
        try CalendarSource.save(calendars, to: file)
        #expect(try CalendarSource.load(from: file) == calendars)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: (any Error).self) { try Secrets.set(.calendar, "https://example.com/old.ics", file: file) }
        #expect(try CalendarSource.load(from: file) == calendars)
        #expect(throws: OatcakeError.self) { try CalendarSource.validatedAddress("http://example.com/private.ics") }
        #expect(throws: OatcakeError.self) { try CalendarSource.validatedAddress("https:private.ics") }

        try CalendarSource.save([], to: file)
        #expect(try CalendarSource.load(from: file, inheritedAddress: "https://example.com/environment.ics").isEmpty)
        #expect(Secrets.moveFromKeychain(file: file, read: { _ in Issue.record("Old account should not be read"); return (0, nil) },
                                        delete: { _ in Issue.record("Old account should not be touched") }))
    }

    @Test func legacyBadgeIdentityIsUniqueAcrossInstallations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/private.json")
        let second = root.appendingPathComponent("second/private.json")
        let earlyBuild = root.appendingPathComponent("early/private.json")
        let address = "https://example.com/calendar.ics"
        try Secrets.set(.calendar, address, file: first)
        try Secrets.set(.calendar, address, file: second)
        let oldID = UUID(uuidString: "A3528273-EE38-4738-8553-8967CBDB50B9")!
        try CalendarSource.save([CalendarSource(id: oldID, name: "Work", colour: .blue, address: address)], to: earlyBuild)
        let files = [first, second, earlyBuild]
        let sources = try files.map { file in try #require(CalendarSource.load(from: file).first) }
        #expect(Set(sources.map(\.id)).count == files.count)
        for (file, source) in zip(files, sources) {
            #expect(source.id != oldID)
            #expect(source.fetchID == oldID)
            #expect(source.cacheFile(in: root).lastPathComponent == "calendar.json")
            #expect(try CalendarSource.load(from: file).first == source)
        }
        #expect(sources.last?.name == "Work")
    }

    @Test func shellCalendarKeepsItsIDWithoutSavingItsAddressOrEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.json")
        let shellURL = "https://example.com/shell-secret.ics"
        let shell = try #require(CalendarSource.load(from: file, inheritedAddress: shellURL).first)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try CalendarSource.load(from: file, inheritedAddress: shellURL) == [shell])
        let saved = CalendarSource(name: "Work", colour: .orange, address: "https://example.com/work.ics")
        try CalendarSource.save([shell, saved], to: file)
        #expect(!readText(file).contains(shellURL))
        #expect(try CalendarSource.load(from: file, inheritedAddress: shellURL) == [shell, saved])
        let inactive = try #require(CalendarSource.load(from: file, inheritedAddress: "").first)
        #expect(inactive.id == shell.id && inactive.address.isEmpty)
        var caches = CalendarFeedCaches()
        caches.setSources([shell, saved], in: root)
        let cache = CalendarCache(updatedAt: "2026-11-25T00:00:00Z")
        caches.receive(cache, from: shell.fetchID)
        #expect(caches[shell.fetchID] == cache)
        #expect(!FileManager.default.fileExists(atPath: shell.cacheFile(in: root).path))
    }

    @Test func shellCalendarDoesNotPreventLegacyMigrationRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.json")
        let pending = Secrets.moveFromKeychain(file: file, read: { _ in (errSecAuthFailed, nil) },
                                              delete: { _ in Issue.record("Denied secret must not be deleted") })
        #expect(!pending)
        let shellURL = "https://example.com/shell.ics"
        #expect(try CalendarSource.load(from: file, inheritedAddress: shellURL).first?.address == shellURL)
        #expect(!CalendarSource.replacesLegacySettings(file))
        let legacy = "https://example.com/legacy.ics"
        var deleted = false
        let retried = Secrets.moveFromKeychain(file: file, read: { _ in (errSecSuccess, legacy) }, delete: { _ in deleted = true })
        #expect(retried && deleted)
        #expect(try CalendarSource.load(from: file, inheritedAddress: shellURL).first?.address == legacy)
        #expect(!readText(file).contains(shellURL))
    }

    @Test func feedFailureKeepsOnlyItsOwnLastGoodEvents() async throws {
        let start = isoString(Date().addingTimeInterval(300)).prefix(19).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") + "Z"
        let server = try await StandIn { request in
            switch request.path {
            case "/work.ics", "/personal.ics":
                let feed = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:\(request.path)\nDTSTART:\(start)\nDURATION:PT30M\nSUMMARY:Test call\nEND:VEVENT\nEND:VCALENDAR"
                return .init(body: Data(feed.utf8))
            case "/bad.ics":
                return .init(body: Data("BEGIN:VCALENDAR\nBEGIN:VEVENT".utf8))
            default:
                return .init(status: 503)
            }
        }
        let work = await fetchCalendar(server.address + "/work.ics", previous: CalendarCache())
        let personal = await fetchCalendar(server.address + "/personal.ics", previous: CalendarCache())
        try #require(work.events.count == 1 && personal.events.count == 1)
        for path in ["/private-token", "/bad.ics"] {
            let failed = await fetchCalendar(server.address + path, previous: work)
            #expect(failed.events == work.events && failed.updatedAt == work.updatedAt)
            #expect(failed.error?.contains(path) == false)
            #expect(MergedCalendar([(UUID(), failed.events), (UUID(), personal.events)]).events.count == 2)
        }
    }

    @Test func lateResultsCannotRestoreRemovedOrReplacedFeeds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func source(_ name: String) -> CalendarSource {
            .init(name: name, colour: .blue, address: "https://example.com/\(name).ics")
        }
        let old = source("Work"), personal = source("Personal"), removed = source("Third")
        var replacement = old
        replacement.replaceAddress("https://example.com/new-work.ics")
        #expect(replacement.id == old.id)
        #expect(replacement.fetchID != old.fetchID)
        let settings = root.appendingPathComponent("private.json")
        try CalendarSource.save([replacement, personal], to: settings)
        #expect(try CalendarSource.load(from: settings).first == replacement)
        var caches = CalendarFeedCaches()
        caches.setSources([old, personal, removed], in: root)
        let good = CalendarCache(updatedAt: "2026-11-25T00:00:00Z")
        let late = CalendarCache(updatedAt: "2026-11-26T00:00:00Z")
        for source in [old, personal, removed] {
            let accepted = caches.receive(good, from: source.id)
            #expect(accepted)
        }
        caches.setSources([replacement, personal], in: root)
        for source in [old, removed] {
            let accepted = caches.receive(late, from: source.id)
            #expect(!accepted)
            #expect(caches[source.id] == nil)
            #expect(!FileManager.default.fileExists(atPath: source.cacheFile(in: root).path))
        }
        #expect(caches[replacement.fetchID]?.updatedAt == nil)
        let accepted = caches.receive(late, from: replacement.fetchID)
        #expect(accepted)
        var reopened = CalendarFeedCaches()
        reopened.setSources([replacement, personal], in: root)
        #expect(reopened[replacement.fetchID] == late)
        #expect(reopened[personal.id] == good)
    }

    @Test func seriesIgnoreSurvivesAMergedStandaloneCopy() throws {
        let from = parseISO("2026-11-25T00:00:00Z")!, to = parseISO("2026-11-28T00:00:00Z")!
        func event(_ details: String) throws -> CalendarEvent {
            try #require(parseCalendar("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:shared-series
            DTSTART:20261125T100000Z
            DURATION:PT30M
            SUMMARY:Weekly sync
            \(details)
            END:VEVENT
            END:VCALENDAR
            """, from: from, to: to).first)
        }
        let series = try event("RRULE:FREQ=WEEKLY;COUNT=2")
        let standalone = try event("DESCRIPTION:https://meet.google.com/abc-defg-hij")
        let ignore = try #require(IgnoredEvent.series(of: series))
        for copies in [[series, standalone], [standalone, series]] {
            let events = MergedCalendar(copies.map { (UUID(), [$0]) }).events
            try #require(events.count == 1)
            #expect(events[0].callLink == standalone.callLink)
            #expect(isIgnored(events[0], [ignore]))
        }
        let remaining = try #require(MergedCalendar([(UUID(), [standalone])]).events.first)
        #expect(remaining.seriesId == nil)
        #expect(isIgnored(remaining, [ignore]))
        var different = remaining
        different.id = "lookalike-\(remaining.id)"
        #expect(!isIgnored(different, [ignore]))

        let reminderID = standalone.id
        let updated = MergedCalendar([(UUID(), [series]), (UUID(), [standalone])]).events
        let actionable = try #require(currentEvent(forReminder: reminderID, in: updated))
        #expect(actionable.callLink == standalone.callLink)
        #expect(actionable.seriesId == series.seriesId)
        #expect(currentEvent(forReminder: reminderID, in: [different]) == nil)
        #expect(currentEvent(forReminder: reminderID, in: updated.filter { !isIgnored($0, [ignore]) }) == nil)
    }

    @Test func mergeExactOccurrencesAndKeepSources() {
        let first = UUID(), second = UUID(), third = UUID()
        let from = parseISO("2026-11-25T00:00:00Z")!, to = parseISO("2026-11-28T00:00:00Z")!
        func events(_ uid: String, _ date: String, link: String = "") -> [CalendarEvent] {
            parseCalendar("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:\(uid)
            DTSTART:\(date)
            DURATION:PT30M
            SUMMARY:Weekly sync
            DESCRIPTION:\(link)
            END:VEVENT
            END:VCALENDAR
            """, from: from, to: to)
        }
        let early = events("other", "20261125T090000Z")
        let original = events("shared", "20261125T100000Z")
        let withLink = events("shared", "20261125T100000Z", link: "https://meet.google.com/abc-defg-hij")
        let distinctUID = events("different", "20261125T100000Z")
        let distinctStart = events("shared", "20261126T100000Z")
        let list = MergedCalendar([(first, original), (second, withLink + distinctStart), (third, early + distinctUID)])
        #expect(list.events.count == 4)
        #expect(list.events.first?.id == early.first?.id)
        #expect(list.events.last?.id == distinctStart.first?.id)
        if let event = withLink.first {
            #expect(list.sourcesByEvent[event.id] == [first, second])
            #expect(list.events.first { $0.id == event.id }?.callLink == event.callLink)
        }
    }
}

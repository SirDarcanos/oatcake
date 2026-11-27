import Foundation

public struct CalendarSource: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    private var cacheID: UUID?
    public var fetchID: UUID { cacheID ?? id }
    public var name: String
    public var colour: SwatchColour
    private var savedAddress: String?
    private var usesShellAddress: Bool?
    private var shellAddress = ""
    public var address: String { usesShellAddress == true ? shellAddress : savedAddress ?? "" }
    var isFromShell: Bool { usesShellAddress == true }
    /// One of this Mac's own calendars (EventKit's calendarIdentifier), read from the Mac's calendar
    /// store rather than fetched from an address. nil for a calendar with a private iCal address.
    public private(set) var macCalendarID: String?
    /// Something to read events from: an address, or one of this Mac's calendars.
    public var isConnected: Bool { !address.isEmpty || macCalendarID != nil }

    private enum CodingKeys: String, CodingKey {
        case id, cacheID, name, colour, savedAddress = "address", usesShellAddress, macCalendarID
    }

    /// Where a calendar address can come from instead of Settings, for trying a build (docs/development.md).
    /// Oatcake's helpers aren't given it (ShellEnvironment).
    public static let environmentVariable = "OATCAKE_CALENDAR_URL"

    // The legacy cache keeps its filename, but its ID must never identify a saved meeting’s source.
    private static let legacyCacheID = UUID(uuidString: "A3528273-EE38-4738-8553-8967CBDB50B9")!

    public init(id: UUID = UUID(), name: String, colour: SwatchColour, address: String) {
        self.id = id
        self.name = name
        self.colour = colour
        savedAddress = address
    }

    public init(id: UUID = UUID(), name: String, colour: SwatchColour, macCalendarID: String) {
        self.id = id
        self.name = name
        self.colour = colour
        self.macCalendarID = macCalendarID
    }

    public func cacheFile(in directory: URL = Paths.data) -> URL {
        directory.appendingPathComponent(fetchID == Self.legacyCacheID ? "calendar.json" : "calendar-\(fetchID.uuidString).json")
    }

    public mutating func replaceAddress(_ address: String) {
        guard isFromShell || self.address != address else { return }
        // Saved meetings keep the source ID, but a replacement feed must never use the old cache.
        savedAddress = address
        usesShellAddress = nil
        shellAddress = ""
        cacheID = UUID()
    }

    public static func nextColour(_ sources: [Self]) -> SwatchColour {
        // Start with contrasting colours for the usual two or three calendars.
        let first: [SwatchColour] = [.blue, .orange, .green, .purple]
        let palette = first + SwatchColour.allCases.filter { !first.contains($0) }
        return palette.first { colour in !sources.contains { $0.colour == colour } }
            ?? palette[sources.count % palette.count]
    }

    private struct PrivateSettings: Codable {
        var calendar: String?
        var calendars: [CalendarSource]?
    }

    public static func load(from file: URL = Paths.secretFile, inheritedAddress: String? = nil) throws -> [Self] {
        let stored: PrivateSettings
        do {
            stored = try JSONDecoder().decode(PrivateSettings.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            stored = PrivateSettings()
        }
        let inherited = (inheritedAddress ?? ProcessInfo.processInfo.environment[environmentVariable] ?? "").trimmed
        if var calendars = stored.calendars {
            // Early test builds saved the legacy cache ID as the calendar’s own ID.
            if let index = calendars.firstIndex(where: { $0.id == legacyCacheID }) {
                calendars[index].cacheID = calendars[index].fetchID
                calendars[index].id = UUID()
                try save(calendars, to: file)
            }
            for index in calendars.indices where calendars[index].isFromShell {
                calendars[index].shellAddress = inherited
            }
            return calendars
        }
        let address = stored.calendar?.trimmed ?? ""
        guard !address.isEmpty || !inherited.isEmpty else { return [] }
        var legacy = CalendarSource(name: "Calendar", colour: .blue, address: address)
        if address.isEmpty {
            // Keep a badge ID without serialising the URL or marking a legacy migration complete.
            legacy.id = try shellSourceID(beside: file)
            legacy.savedAddress = nil
            legacy.usesShellAddress = true
            legacy.shellAddress = inherited
        } else {
            legacy.cacheID = legacyCacheID
            try save([legacy], to: file)
        }
        return [legacy]
    }

    private static func shellSourceID(beside settings: URL) throws -> UUID {
        let directory = settings.deletingLastPathComponent()
        let file = directory.appendingPathComponent("shell-calendar-id.json")
        if let id = tryJSON(UUID.self, file) { return id }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeAtomic(file, try encodeJSON(id) + "\n", permissions: 0o600)
        return id
    }

    public static func save(_ calendars: [Self], to file: URL = Paths.secretFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Even an empty list records that the old fallback has been superseded.
        try writeAtomic(file, try encodeJSON(PrivateSettings(calendars: calendars)) + "\n", permissions: 0o600)
    }

    static func replacesLegacySettings(_ file: URL) -> Bool {
        tryJSON(PrivateSettings.self, file)?.calendars != nil
    }

    public static func validatedAddress(_ value: String) throws -> String {
        let address = value.trimmed.replacingOccurrences(of: "^webcal:", with: "https:", options: [.regularExpression, .caseInsensitive])
        let url = try calendarURL(address)
        return url.absoluteString
    }
}

/// Keep the last result per feed and reject results from requests that outlived their source.
public struct CalendarFeedCaches: Sendable {
    private var active: Set<UUID> = []
    private var files: [UUID: URL] = [:]
    private var caches: [UUID: CalendarCache] = [:]

    public init() {}

    public var values: Dictionary<UUID, CalendarCache>.Values { caches.values }
    public subscript(_ id: UUID) -> CalendarCache? { caches[id] }

    public mutating func setSources(_ sources: [CalendarSource], in directory: URL = Paths.data) {
        let oldActive = active
        let oldFiles = files
        let connected = sources.filter(\.isConnected)
        active = Set(connected.map(\.fetchID))
        files = [:]
        // This Mac's calendars are read afresh from its own store, so they have no file of their own.
        for source in connected where !source.isFromShell && source.macCalendarID == nil {
            let file = source.cacheFile(in: directory)
            files[source.fetchID] = file
            if oldFiles[source.fetchID] != file { caches[source.fetchID] = CalendarCache.load(file) }
        }
        for id in oldActive.subtracting(active) {
            caches[id] = nil
            if let file = oldFiles[id] { try? FileManager.default.removeItem(at: file) }
        }
    }

    @discardableResult
    public mutating func receive(_ cache: CalendarCache, from id: UUID) -> Bool {
        guard active.contains(id) else { return false }
        caches[id] = cache
        if let file = files[id] { try? cache.save(to: file) }
        return true
    }
}

public struct MergedCalendar: Sendable {
    public let events: [CalendarEvent]
    public let sourcesByEvent: [String: [UUID]]

    public init(_ feeds: [(id: UUID, events: [CalendarEvent])]) {
        var events: [String: CalendarEvent] = [:]
        var sources: [String: [UUID]] = [:]
        for feed in feeds {
            for event in feed.events {
                if var existing = events[event.id] {
                    // One feed can flatten a series into standalone events. Keep the series's
                    // identity for Ignore even if the call link comes from the standalone copy.
                    existing.seriesId = existing.seriesId ?? event.seriesId
                    if existing.callLink == nil, let link = event.callLink { existing.meetUrl = link }
                    events[event.id] = existing
                } else {
                    events[event.id] = event
                }
                if sources[event.id]?.last != feed.id { sources[event.id, default: []].append(feed.id) }
            }
        }
        self.events = events.values.sorted {
            $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate
        }
        sourcesByEvent = sources
    }
}

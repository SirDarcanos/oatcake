import Foundation

/// Where Oatcake keeps its own data. Meetings live wherever Settings › Meetings folder says.
public enum Paths {
    /// OATCAKE_DATA_DIR points a development copy at another folder, so it leaves your own data alone.
    public static let data = ProcessInfo.processInfo.environment["OATCAKE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oatcake", isDirectory: true)
    public static let models = data.appendingPathComponent("models", isDirectory: true)
    public static let recordings = data.appendingPathComponent("recordings", isDirectory: true)
    public static let voiceprints = data.appendingPathComponent("voiceprints.json")
    public static let config = data.appendingPathComponent("config.json")
    public static let prep = data.appendingPathComponent("prep.json")
    /// Which call reminders have gone out (SentReminders).
    public static let reminders = data.appendingPathComponent("reminders.json")
    /// The calendar's private address (Secrets). Not "secrets.json": that's the Electron version's file.
    public static let secretFile = data.appendingPathComponent("private.json")
    public static let updateLog = data.appendingPathComponent("update.log")
}

public struct OatcakeError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension FileManager {
    func exists(_ url: URL) -> Bool { fileExists(atPath: url.path) }

    func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }
}

/**
 * Replaces a file in one step: readers never see it half-written, and a crash mid-write leaves the
 * old file. The temporary file gets a random name and must not already exist, so a symlink planted
 * next to the target (say, in a synced Meetings folder) can't redirect the write elsewhere.
 */
public func writeAtomic(_ url: URL, _ data: Data, permissions: Int? = nil) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(12)).tmp")
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions ?? 0o644))
    guard fd >= 0 else { throw OatcakeError("Couldn't write \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(tmp.path, url.path) == 0 else { throw OatcakeError("Couldn't save \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

public func writeAtomic(_ url: URL, _ text: String, permissions: Int? = nil) throws {
    try writeAtomic(url, Data(text.utf8), permissions: permissions)
}

/// Resolves a path relative to `root`, refusing anything that escapes it, as written or through a
/// symbolic link: a link inside `root` counts only if it leads somewhere inside `root` too.
public func resolveInside(_ root: URL, _ rel: String) throws -> URL {
    let base = root.standardizedFileURL
    let full = (rel.isEmpty ? base : base.appendingPathComponent(rel)).standardizedFileURL
    let outside = OatcakeError("Path is outside the Meetings folder: \(rel)")
    guard full.path == base.path || full.path.hasPrefix(base.path + "/") else { throw outside }
    // Only links below `root` need following: without one, a path is where it says (`root` itself
    // may be a link; it's the folder you chose). This runs for every meeting each time the tree is
    // read, so it's an lstat for each part, and `root` is resolved only once a link turns up.
    var realRoot: String?
    var path = base.path
    var info = stat()
    for part in full.path.dropFirst(base.path.count).split(separator: "/") {
        path += "/" + part
        // Nothing there (yet): nothing further along to follow.
        guard lstat(path, &info) == 0 else { break }
        guard info.st_mode & S_IFMT == S_IFLNK else { continue }
        realRoot = realRoot ?? realPath(base.path)
        // A link that leads nowhere, or round in a loop, leads nowhere inside either.
        guard let realRoot, let target = realPath(path), target == realRoot || target.hasPrefix(realRoot + "/") else { throw outside }
    }
    return full
}

/// The path with every link in it followed, or nil when one can't be.
private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The path of `url` relative to `root` ("" for root itself).
func relativePath(_ url: URL, to root: URL) -> String {
    let base = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == base { return "" }
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
}

// MARK: - JSON

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

public func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// nil when the file is missing or can't be read as T.
public func tryJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    try? readJSON(type, url)
}

public func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try jsonEncoder.encode(value), as: UTF8.self)
}

public func readText(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    // A stray byte from another editor doesn't make the whole file read as empty (and then get saved over).
    return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
}

/// Keeps a file that can't be read beside itself ("config.unreadable.json") before a new one takes
/// its place. Returns where it went.
@discardableResult
func keepUnreadable(_ file: URL) -> URL {
    let kept = file.deletingPathExtension().appendingPathExtension("unreadable").appendingPathExtension(file.pathExtension)
    // The same unreadable file is met again every time it's read, until something replaces it: it's kept once.
    if let before = try? Data(contentsOf: kept), let now = try? Data(contentsOf: file), before == now { return kept }
    // Copied beside it and then renamed over the earlier kept copy, so a copy that fails loses neither.
    let arriving = kept.appendingPathExtension("arriving")
    try? FileManager.default.removeItem(at: arriving)
    if (try? FileManager.default.copyItem(at: file, to: arriving)) != nil, rename(arriving.path, kept.path) != 0 {
        try? FileManager.default.removeItem(at: arriving)
    }
    return kept
}

extension String {
    /// Whitespace and newlines trimmed from both ends.
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// As much of the start as fits in `bytes` of UTF-8, back to a whole character: a budget kept in
    /// bytes (as the model's tokens are counted) and cut in characters is three times over in
    /// Chinese or Japanese, where a character is three bytes.
    func prefix(utf8 bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var end = startIndex
        var used = 0
        for index in indices {
            let size = utf8.distance(from: index, to: self.index(after: index))
            guard used + size <= bytes else { break }
            used += size
            end = self.index(after: index)
        }
        return String(self[..<end])
    }
}

// MARK: - Dates

/// Dates in folder names, to-dos and the windows are Gregorian, whatever calendar the Mac is set to
/// (a Buddhist or Japanese calendar counts years differently, and some have a thirteenth month).
public var gregorian: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

/// The ISO 8601 formatters, for use from any thread: ISO8601DateFormatter isn't marked as safe to
/// share, so they're used one call at a time, behind a lock. (Date's own ISO 8601 format style
/// would need no lock, but it cuts the milliseconds short where this rounds them, so times already
/// written would read back a millisecond out.)
private final class ISOFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()

    func string(from date: Date) -> String { lock.withLock { withFraction.string(from: date) } }
    func date(from string: String) -> Date? { lock.withLock { withFraction.date(from: string) ?? plain.date(from: string) } }
}
private let isoFormatters = ISOFormatters()

/// "2026-11-05T14:00:02.682Z", the way the Electron version wrote times.
public func isoString(_ date: Date) -> String { isoFormatters.string(from: date) }

/// Reads ISO 8601 times with or without fractional seconds.
public func parseISO(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    return isoFormatters.date(from: string)
}

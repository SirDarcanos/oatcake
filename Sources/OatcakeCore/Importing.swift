// What the Granola and Quill importers share: what an import did, the loop over an export's notes
// or meetings, how one is written into the Meetings folder, and how those already there are known.

import Foundation

/// What an import did.
public struct ImportResult: Sendable {
    public var imported = 0
    /// Already in the Meetings folder (the same note or meeting).
    public var skipped = 0
    /// Notes or meetings without an id or a readable date, or that couldn't be written.
    public var unreadable = 0
    /// Where the new meetings went, relative to the Meetings folder.
    public var folder: String
}

/// How far an import has got: meetings handled so far, out of how many in the export (0 of 0 while it is still being read).
public typealias ImportProgress = @Sendable (_ done: Int, _ total: Int) -> Void

/// One note or meeting of an export, as the files its folder will hold: `files` maps a name to its
/// text, `moving` to a file that's moved in (a recording).
struct ImportedMeeting {
    var files: [String: String]
    var moving: [String: URL] = [:]
}

/**
 * Imports each row of an export into `folder` in the Meetings folder. A row needs an id (a UUID) and
 * a date; one without is counted as unreadable. One already there (its id is under `idKey` in some
 * meeting.json, wherever that meeting was moved) is skipped. Rows that share a title, like a weekly
 * meeting, go in a subfolder named after it. `meeting` turns a row into its files, or nil when
 * there's nothing in it to import. A row that can't be made or written (a title too long for a
 * folder name, say) is counted and passed over: the ones after it still come in, on this run and the
 * next. If nothing at all could be written, the first reason is thrown.
 */
func importMeetings<Row>(_ rows: [Row], into root: URL, folder: String, idKey: String, progress: ImportProgress,
                         id: (Row) -> String, title: (Row) -> String, startedAt: (Row) -> Date?,
                         meeting: (Row, _ id: String, _ title: String, _ startedAt: Date) throws -> ImportedMeeting?) throws -> ImportResult {
    progress(0, rows.count)
    var known = knownIds(root, key: idKey)
    var titles: [String: Int] = [:]
    for row in rows { titles[title(row), default: 0] += 1 }

    var result = ImportResult(folder: folder)
    // Why the first one that couldn't be written couldn't be.
    var failure: Error?
    for (i, row) in rows.enumerated() {
        defer { progress(i + 1, rows.count) }
        let id = id(row).trimmed.lowercased()
        guard id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil, let started = startedAt(row) else {
            result.unreadable += 1
            continue
        }
        if known.contains(id) {
            result.skipped += 1
            continue
        }
        let title = title(row)
        let made: ImportedMeeting?
        do {
            made = try meeting(row, id, title, started)
        } catch {
            result.unreadable += 1
            continue
        }
        guard let made else { continue }
        let series = (titles[title] ?? 0) > 1 ? seriesFolder(title) : ""
        do {
            try writeImported(root, base: [folder, series].filter { !$0.isEmpty }.joined(separator: "/"),
                              title: title, startedAt: started, files: made.files, moving: made.moving)
        } catch {
            if failure == nil { failure = error }
            result.unreadable += 1
            continue
        }
        known.insert(id)
        result.imported += 1
    }
    // Nothing could be written at all (no room, or the Meetings folder can't be written to): say why.
    if result.imported == 0, result.skipped == 0, let failure { throw failure }
    return result
}

/// The ids under `key` (a bare id, or a link ending in one) of every meeting already in the Meetings folder.
func knownIds(_ root: URL, key: String) -> Set<String> {
    var ids = Set<String>()
    let idPattern = try! NSRegularExpression(pattern: "[0-9a-f-]{36}", options: .caseInsensitive)
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
        guard url.lastPathComponent == "meeting.json" else { continue }
        // An unreadable meeting.json can't be a duplicate.
        guard let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              let note = json[key] as? String, let match = firstMatch(idPattern, note)?[0] else { continue }
        ids.insert(match.lowercased())
    }
    return ids
}

/// A series folder's name.
func seriesFolder(_ title: String) -> String {
    let name = safeName(title)
    return name.isEmpty ? "Untitled" : name
}

/**
 * Writes an imported meeting into `base`: `files` maps a file name to its text, `moving` to a file
 * moved in. Two meetings with the same title in the same minute are different meetings: the second is
 * numbered. Written beside its final place, then renamed in, so a half-written meeting never shows.
 */
func writeImported(_ root: URL, base: String, title: String, startedAt: Date, files: [String: String], moving: [String: URL] = [:]) throws {
    let fm = FileManager.default
    let name = meetingFolderName(title: title, startedAt: startedAt)
    var rel = base + "/" + name
    var n = 2
    while fm.exists(try resolveInside(root, rel)) {
        rel = base + "/" + "\(name) (\(n))"
        n += 1
    }
    let dest = try resolveInside(root, rel)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = dest.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString.prefix(8))")
    do {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        for (file, text) in files { try text.write(to: tmp.appendingPathComponent(file), atomically: false, encoding: .utf8) }
        for (file, source) in moving { try fm.moveItem(at: source, to: tmp.appendingPathComponent(file)) }
        try fm.moveItem(at: tmp, to: dest)
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
}

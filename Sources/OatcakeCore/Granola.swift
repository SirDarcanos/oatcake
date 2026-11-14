// Imports Granola's export: a .zip holding one or more CSV files (or one of those CSVs), one row per
// note with document_id, document_title, document_created, summary, notes and transcript. Each note
// becomes a meeting folder (summary.md, transcript.md, notes.md when Granola kept any, meeting.json)
// under a "Granola" folder, with notes that share a title grouped in a subfolder. A note already in
// the Meetings folder (same Granola note, wherever it was moved) is skipped.

import Foundation

public let granolaFolder = "Granola"
private let noteURL = "https://notes.granola.ai/d/"
private let requiredColumns = ["document_id", "document_title", "document_created", "summary", "transcript"]

/// RFC 4180 CSV: quoted fields may hold commas, newlines and doubled quotes.
public func parseCsv(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var chars = Array(text.unicodeScalars)[...]
    while let c = chars.popFirst() {
        if quoted {
            if c == "\"" {
                if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false }
            } else {
                field.unicodeScalars.append(c)
            }
        } else if c == "\"" && field.isEmpty {
            quoted = true
        } else if c == "," {
            row.append(field)
            field = ""
        } else if c == "\n" || c == "\r" {
            if c == "\r" && chars.first == "\n" { chars.removeFirst() }
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        } else {
            field.unicodeScalars.append(c)
        }
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows.filter { $0.count > 1 || $0.first != "" }
}

private func readExport(_ file: URL) throws -> [[String: String]] {
    let ext = file.pathExtension.lowercased()
    if ext == "csv" { return try readCsvs([file]) }
    guard ext == "zip" else { throw OatcakeError("Pick the .zip (or .csv) that Granola's export gave you.") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-granola-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
        try runCapturing("/usr/bin/ditto", ["-x", "-k", file.path, tmp.path])
    } catch {
        throw OatcakeError("Couldn't open that .zip. Is it the file Granola's export gave you?")
    }
    var csvs: [URL] = []
    let walker = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    while let url = walker?.nextObject() as? URL {
        if url.lastPathComponent == "__MACOSX" { walker?.skipDescendants(); continue }
        if url.pathExtension.lowercased() == "csv" { csvs.append(url) }
    }
    guard !csvs.isEmpty else { throw OatcakeError("That .zip has no CSV in it. Is it the file Granola's export gave you?") }
    return try readCsvs(csvs.sorted { $0.path < $1.path })
}

private func readCsvs(_ csvs: [URL]) throws -> [[String: String]] {
    var rows: [[String: String]] = []
    for csv in csvs {
        var text = readText(csv)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let table = parseCsv(text)
        let header = table.first ?? []
        let missing = requiredColumns.filter { !header.contains($0) }
        if !missing.isEmpty {
            throw OatcakeError("\(csv.lastPathComponent) doesn't look like a Granola export (no \(missing.joined(separator: ", ")) column).")
        }
        for cells in table.dropFirst() {
            rows.append(Dictionary(header.enumerated().map { ($1, $0 < cells.count ? cells[$0] : "") }, uniquingKeysWith: { a, _ in a }))
        }
    }
    guard !rows.isEmpty else { throw OatcakeError("There are no notes in that export.") }
    return rows
}

/// Granola's transcript is one line per utterance, with no times or names: one paragraph each.
private func transcriptMarkdown(_ text: String) -> String {
    text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
}

public func importGranola(_ file: URL, into root: URL, progress: ImportProgress = { _, _ in }) throws -> ImportResult {
    let rows = try readExport(file)
    struct Meta: Encodable {
        var title: String
        var startedAt: String
        var source = "granola"
        var granolaNote: String
    }
    return try importMeetings(rows, into: root, folder: granolaFolder, idKey: "granolaNote", progress: progress,
                              id: { $0["document_id"] ?? "" },
                              title: { r in (r["document_title"] ?? "").trimmed.isEmpty ? "Untitled" : (r["document_title"] ?? "").trimmed },
                              startedAt: { parseISO(($0["document_created"] ?? "").trimmed) }) { r, id, title, started in
        var files = ["summary.md": (r["summary"] ?? "").trimmed + "\n",
                     "transcript.md": transcriptMarkdown(r["transcript"] ?? ""),
                     "meeting.json": try encodeJSON(Meta(title: title, startedAt: isoString(started), granolaNote: noteURL + id)) + "\n"]
        if let notes = r["notes"]?.trimmed, !notes.isEmpty { files["notes.md"] = notes + "\n" }
        return ImportedMeeting(files: files)
    }
}

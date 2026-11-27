// Who's who in a meeting that's already saved: the speakers its transcript names, and Rename
// speakers…, which gives them other names in that meeting only.

import Foundation

/// A paragraph of Oatcake's own transcript, "**[12:34] Name:** text": the time, the name and what was
/// said. Transcripts imported from another app (Granola's) keep that app's names and aren't renamed.
private let paragraph = try! NSRegularExpression(pattern: #"^(\*\*\[(\#(stampForm))\]\s+)(.+?)(:\*\*)\s*(.*)$"#, options: .anchorsMatchLines)

/// Stands for any of several voices, so it's never renamed as if it were one person.
private let severalPeople = "Several people"

/// One of the speakers in a saved meeting, for Rename speakers…: how much they said, and when and
/// what they first said, to tell who's who by without the audio.
public struct MeetingSpeaker: Identifiable, Equatable, Sendable {
    public var name: String
    public var paragraphs: Int
    public var firstAt: String
    public var firstWords: String
    public var id: String { name }
}

/// The speakers in a transcript Oatcake wrote, in the order they first speak, without "Several
/// people". Empty for any other kind of transcript.
public func meetingSpeakers(_ transcript: String) -> [MeetingSpeaker] {
    let text = transcript as NSString
    var order: [String] = []
    var found: [String: MeetingSpeaker] = [:]
    for m in paragraph.matches(in: transcript, range: NSRange(location: 0, length: text.length)) {
        let name = text.substring(with: m.range(at: 3))
        guard name != severalPeople else { continue }
        if found[name] == nil {
            order.append(name)
            found[name] = MeetingSpeaker(name: name, paragraphs: 0, firstAt: padStamp(text.substring(with: m.range(at: 2))),
                                         firstWords: text.substring(with: m.range(at: 5)).trimmed)
        }
        found[name]?.paragraphs += 1
    }
    return order.compactMap { found[$0] }
}

/// The renames that change anything: a blank new name, or the old one again, leaves that speaker as
/// they are, and "Several people" is never renamed or given to anyone.
private func effective(_ renames: [String: String]) -> [String: String] {
    renames.mapValues(\.trimmed).filter { old, new in !new.isEmpty && old != new && old != severalPeople && new != severalPeople }
}

/**
 * The speakers a rename makes one, under the name they'll share, in the order they speak: a name
 * given to someone else already in the meeting, or to two of them. Names swapped aren't a merge.
 * Rename speakers… says so before it's done, because the transcript can't tell them apart again.
 */
public func speakersMerged(_ speakers: [String], by renames: [String: String]) -> [(name: String, speakers: [String])] {
    let changes = effective(renames)
    var groups: [(name: String, speakers: [String])] = []
    for speaker in speakers {
        let name = changes[speaker] ?? speaker
        if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].speakers.append(speaker) } else { groups.append((name, [speaker])) }
    }
    return groups.filter { $0.speakers.count > 1 }
}

extension Meetings {
    /**
     * Rename speakers…: gives a saved meeting's speakers other names (old name → new), in that
     * meeting only. The transcript's labels change, never what was said; the summary and to-dos say
     * the new names where they said the old ones (as whole words, as naming voices later does); so
     * does meeting.json's list of people. Two names can swap, and a name given to someone already in
     * the meeting makes them one speaker. A blank new name leaves that speaker as they are.
     *
     * The fingerprint Oatcake saved from this call goes with the name (moveCallVoiceprints), so the
     * next call isn't recognised as the wrong person too. Other meetings aren't touched.
     */
    public func renameSpeakers(_ rel: String, _ renames: [String: String], me: String, voiceprints: URL = Paths.voiceprints) throws {
        let changes = effective(renames)
        guard !changes.isEmpty else { return }
        guard !rel.isEmpty else { throw OatcakeError("That isn't a meeting") }
        let files = try read(rel)

        // Last paragraph first, so the ranges still to change stay where they were.
        let transcript = NSMutableString(string: files.transcript)
        for m in paragraph.matches(in: files.transcript, range: NSRange(location: 0, length: transcript.length)).reversed() {
            if let new = changes[transcript.substring(with: m.range(at: 3))] { transcript.replaceCharacters(in: m.range(at: 3), with: new) }
        }
        guard transcript as String != files.transcript else { return }
        try write(rel, .transcript, transcript as String)
        for (file, text) in [(MeetingFile.summary, files.summary), (.todo, files.todo), (.draft, files.draft)] where !text.isEmpty {
            let renamed = renamePeople(text, changes)
            if renamed != text { try write(rel, file, renamed) }
        }

        var call: String?
        let dir = try resolveInside(root, rel)
        let metaFile = dir.appendingPathComponent("meeting.json")
        if let data = fileInside(root, dir, "meeting.json").flatMap({ try? Data(contentsOf: $0) }), var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            call = meta["recording"] as? String
            if let people = meta["participants"] as? [String] {
                var renamed: [String] = []
                for name in people.map({ changes[$0] ?? $0 }) where !renamed.contains(name) { renamed.append(name) }
                if renamed != people {
                    meta["participants"] = renamed
                    let written = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    try writeAtomic(metaFile, written + Data("\n".utf8))
                }
            }
        }
        if let call { try moveCallVoiceprints(call: call, renames: changes, me: me, file: voiceprints) }
    }
}

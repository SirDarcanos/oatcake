import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct SaveTests {
    /// Saving involves no model: the meeting is written, and its summary is a separate step that can fail and be tried again.
    @Test func savesWithoutTheModel() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recDir = tmp.appendingPathComponent("rec"), root = tmp.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let analysis = Analysis(title: "Weekly sync", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Morning all."), Line(speaker: "A", start: 4, end: 6, text: "Hi Sam.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.outputDir = root.path
        config.keepAudio = true
        config.llm = LlmConfig(model: LlmConfig.ownServer) // no endpoint: the model can't be reached
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Weekly sync", folder: "", startedAt: Date(), state: .processed)

        let saved = try saveMeeting(config, rec, decisions: ["A": .name("Alex Kim")], folder: "")
        let out = root.appendingPathComponent(saved)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("meeting.json").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
        #expect(readText(out.appendingPathComponent("transcript.md")).contains("**[00:04] Alex Kim:** Hi Sam."))
        #expect(FileManager.default.fileExists(atPath: recDir.appendingPathComponent("saved.json").path))
        // Writing the summary fails while no model is set up, and leaves the meeting alone.
        await #expect(throws: OatcakeError("Set the endpoint and model in Settings first.")) { try await writeSummary(config, meeting: saved) }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))

        // When the model has answered, its summary goes where the meeting is by then (it was renamed
        // meanwhile), and a to-do added in the meantime is kept above the model's.
        let meetings = Meetings(root: root)
        let renamed = try meetings.retitle(saved, to: "Weekly sync with Alex")
        try meetings.write(renamed, .todo, "- [ ] Added while the model was writing\n")
        try writeSummary(SummaryDraft(summary: "## Topic\nDone.\n", todo: "- [ ] From the model — Alex Kim\n"), config: config, meeting: renamed)
        let files = try meetings.read(renamed)
        #expect(files.summary == "## Topic\nDone.\n")
        #expect(files.todo == "- [ ] Added while the model was writing\n- [ ] From the model — Alex Kim\n")

        // Text typed into the summary while the model was writing is kept, with the model's below it.
        try meetings.write(renamed, .summary, "My own line.\n")
        try writeSummary(SummaryDraft(summary: "## Topic\nDone.\n", todo: ""), config: config, meeting: renamed)
        #expect(try meetings.read(renamed).summary == "My own line.\n\n## Topic\nDone.\n")
    }

    /// Regenerate puts the new part in place of the old and leaves the rest of the meeting alone. It
    /// writes nothing when that part was changed meanwhile, or the model's answer is empty or unreadable.
    @Test func regenerateReplacesOnePart() throws {
        let meetings = TestMeetings()
        defer { meetings.remove() }
        let rel = "Team/2026-11-09 1000 Weekly sync"
        let old = "## Old summary\nMy edits.\n"
        try meetings.write(rel, .summary, old)
        try meetings.write(rel, .transcript, "**[00:00] Sam:** A decision.\n")
        try meetings.write(rel, .notes, "- My notes\n")
        try meetings.write(rel, .todo, "- [x] Done\n- [ ] My own task\n")
        var config = Config.defaults()
        config.outputDir = meetings.root.path
        let before = try Meetings(root: meetings.root).read(rel)
        let draft = SummaryDraft(summary: "## New summary\nA decision.\n", todo: "- [ ] Generated task\n")
        try writeRegenerated(.summary, draft, config: config, meeting: rel, previous: old)
        var after = try Meetings(root: meetings.root).read(rel)
        #expect(after.summary == draft.summary)
        #expect(after.transcript == before.transcript && after.notes == before.notes && after.todo == before.todo && after.meta == before.meta)
        try writeRegenerated(.todos, draft, config: config, meeting: rel, previous: before.todo)
        after = try Meetings(root: meetings.root).read(rel)
        #expect(after.todo == draft.todo && after.summary == draft.summary && after.notes == before.notes)
        // Changed in another editor while the model was writing: what's there now stays.
        #expect(throws: (any Error).self) { try writeRegenerated(.summary, draft, config: config, meeting: rel, previous: old) }
        #expect(throws: (any Error).self) { try writeRegenerated(.todos, draft, config: config, meeting: rel, previous: before.todo) }
        // An empty summary, or to-dos that couldn't be read from the model's reply: the old ones stay.
        #expect(throws: (any Error).self) {
            try writeRegenerated(.summary, SummaryDraft(summary: " \n", todo: ""), config: config, meeting: rel, previous: draft.summary)
        }
        #expect(throws: (any Error).self) {
            try writeRegenerated(.todos, SummaryDraft(summary: "", todo: "", todoProblem: todosUnreadMessage), config: config, meeting: rel, previous: draft.todo)
        }
        after = try Meetings(root: meetings.root).read(rel)
        #expect(after.summary == draft.summary && after.todo == draft.todo)
        // A call the model now finds no to-dos in: the list is emptied.
        try writeRegenerated(.todos, SummaryDraft(summary: "", todo: ""), config: config, meeting: rel, previous: draft.todo)
        #expect(try Meetings(root: meetings.root).read(rel).todo == "")
    }

    /// Two voices merged into one person in review give one fingerprint for the call, from the one
    /// that spoke most. With no name set in Settings, your own lines are saved as "Me".
    @Test func mergedVoicesAndNoNameOfYourOwn() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("rec"), prints = tmp.appendingPathComponent("voiceprints.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Config.defaults()
        config.myName = " "
        config.outputDir = tmp.appendingPathComponent("Meetings").path
        config.keepAudio = true
        // B is a stray forty seconds of A; it's listed first here so that the order they come in isn't what decides.
        let analysis = Analysis(title: "Call", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:30:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Morning."), Line(speaker: "A", start: 4, end: 6, text: "Hi."), Line(speaker: "B", start: 20, end: 22, text: "Yes.")],
                                speakers: [SpeakerInfo(id: "B", seconds: 40, embedding: [0, 1], suggestion: nil, quotes: []),
                                           SpeakerInfo(id: "A", seconds: 1200, embedding: [1, 0], suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: dir, title: "Call", folder: "", startedAt: Date(), state: .processed)

        let path = try saveMeeting(config, rec, decisions: ["A": .name("Alex Kim"), "B": .merge(into: "A")], folder: "", voiceprints: prints)
        #expect(Voiceprints.load(prints).people["Alex Kim"]?.samples.map(\.embedding) == [[1, 0]])
        let files = try Meetings(root: config.meetingsRoot).read(path)
        #expect(files.transcript.hasPrefix("**[00:01] Me:** Morning.") && files.meta.participants == ["Me", "Alex Kim"])
    }

    /// Two calls with the same title that started in the same minute are two meetings; saving one again reuses its own folder.
    @Test func sameMinuteCallsKeepTheirOwnFolders() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var config = Config.defaults()
        config.outputDir = tmp.appendingPathComponent("Meetings").path
        config.keepAudio = true
        config.llm = LlmConfig(model: LlmConfig.ownServer) // no endpoint: the model can't be reached
        func recording(_ id: String, at startedAt: String, saying text: String) throws -> Recording {
            let dir = tmp.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let analysis = Analysis(title: "Call", startedAt: startedAt, endedAt: startedAt, lines: [Line(speaker: me, start: 1, end: 3, text: text)],
                                    speakers: [], echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
            try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
            return Recording(id: id, dir: dir, title: "Call", folder: "", startedAt: Date(), state: .processed)
        }
        let transcript = { (path: String) in readText(config.meetingsRoot.appendingPathComponent(path).appendingPathComponent("transcript.md")) }

        let first = try saveMeeting(config, try recording("2026-11-10T14-00-10-000Z", at: "2026-11-10T14:00:10.000Z", saying: "First call."),
                                    decisions: [:], folder: "")
        let later = try recording("2026-11-10T14-00-45-000Z", at: "2026-11-10T14:00:45.000Z", saying: "Second call.")
        let second = try saveMeeting(config, later, decisions: [:], folder: "")
        #expect(second == first + " (2)")
        #expect(transcript(first).contains("First call."))
        #expect(transcript(second).contains("Second call."))

        let again = try saveMeeting(config, later, decisions: [:], folder: "")
        #expect(again == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.outputDir).count == 2)
    }

    /// The title and folder chosen in review are the ones saved, and a long turn is split at pauses.
    @Test func savesUnderTheReviewedTitleInShorterParagraphs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.outputDir = tmp.appendingPathComponent("Meetings").path
        config.keepAudio = true
        let dir = tmp.appendingPathComponent("rec")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One person talking for 80 s in ten-second stretches with half-second pauses, then a reply.
        let turn = (0..<8).map { Line(speaker: "A", start: Double($0) * 10, end: Double($0) * 10 + 9.5, text: "Part \($0 + 1).") }
        let analysis = Analysis(title: "Call", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:02:00.000Z",
                                lines: turn + [Line(speaker: me, start: 82, end: 84, text: "Thanks.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 76, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: dir, title: "Call", folder: "", startedAt: Date(), state: .processed)

        let path = try saveMeeting(config, rec, decisions: ["A": .name("Alex Kim")], folder: "Clients/Acme", title: "  Acme kickoff ")
        #expect(path.hasPrefix("Clients/Acme/") && path.hasSuffix(" Acme kickoff"))
        let files = try Meetings(root: config.meetingsRoot).read(path)
        #expect(files.meta.title == "Acme kickoff")
        let paragraphs = parseTranscript(files.transcript)
        #expect(paragraphs.map(\.speaker) == ["Alex Kim", "Alex Kim", "Alex Kim", "Sam Taylor"])
        #expect(paragraphs.map(\.stamp) == ["00:00", "00:30", "01:00", "01:22"])
        #expect(paragraphs[0].text == "Part 1. Part 2. Part 3.")
    }

    /// A voice merged into one that's left out goes with it: neither is in the meeting, and neither is remembered.
    @Test func mergedIntoALeftOutVoice() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recDir = tmp.appendingPathComponent("rec"), root = tmp.appendingPathComponent("Meetings"), voiceprints = tmp.appendingPathComponent("voiceprints.json")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let speaker = { (id: String, seconds: Double, embedding: [Float]) in SpeakerInfo(id: id, seconds: seconds, embedding: embedding, suggestion: nil, quotes: []) }
        let analysis = Analysis(title: "Catch-up", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 2, text: "Shall we start?"), Line(speaker: "A", start: 10, end: 12, text: "Table for two."),
                                        Line(speaker: "B", start: 20, end: 22, text: "By the window."), Line(speaker: "C", start: 30, end: 32, text: "Yes, go ahead.")],
                                speakers: [speaker("A", 300, [1, 0]), speaker("B", 45, [0, 1]), speaker("C", 60, [1, 1])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.outputDir = root.path
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Catch-up", folder: "", startedAt: Date(), state: .processed)

        // A isn't on the call, and B is A again.
        let saved = try saveMeeting(config, rec, decisions: ["A": .ignore, "B": .merge(into: "A"), "C": .name("Alex Kim")],
                                    folder: "", voiceprints: voiceprints)
        let out = root.appendingPathComponent(saved)
        let transcript = readText(out.appendingPathComponent("transcript.md"))
        #expect(!transcript.contains("Table for two.") && !transcript.contains("By the window."))
        #expect(transcript.contains("**[00:30] Alex Kim:** Yes, go ahead."))
        let meta = try readJSON(MeetingMeta.self, out.appendingPathComponent("meeting.json"))
        #expect(meta.participants == ["Sam Taylor", "Alex Kim"])
        #expect(Array(Voiceprints.load(voiceprints).people.keys) == ["Alex Kim"])
    }

    /// What review decided for each voice is what's saved: merged into another, several people, or left out.
    @Test func mergedMixedAndIgnoredVoices() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let recDir = tmp.appendingPathComponent("rec"), root = tmp.appendingPathComponent("Meetings"), voiceprints = tmp.appendingPathComponent("voiceprints.json")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let speaker = { (id: String, seconds: Double, embedding: [Float]?) in SpeakerInfo(id: id, seconds: seconds, embedding: embedding, suggestion: nil, quotes: []) }
        let analysis = Analysis(title: "Planning", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 2, text: "Shall we start?"), Line(speaker: "A", start: 10, end: 12, text: "Yes."),
                                        Line(speaker: "B", start: 20, end: 22, text: "Still me."), Line(speaker: "C", start: 30, end: 32, text: "We agree."),
                                        Line(speaker: "D", start: 40, end: 42, text: "Hold music."), Line(speaker: "E", start: 50, end: 52, text: "And me.")],
                                speakers: [speaker("A", 300, [1, 0]), speaker("B", 45, [0, 1]), speaker("C", 60, [1, 1]), speaker("D", 50, [0, 0]), speaker("E", 40, [1, 0])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        // The call's notes come from the recording's own folder.
        try encodeJSON([Note(at: nil, text: "Agenda"), Note(at: 65, text: "Budget agreed")]).write(to: recDir.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.outputDir = root.path
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Planning", folder: "", startedAt: Date(), state: .processed)

        // B is A again; C is several people; D isn't anyone; E was left unnamed.
        let saved = try saveMeeting(config, rec, decisions: ["A": .name("Alex Kim"), "B": .merge(into: "A"), "C": .mixed, "D": .ignore, "E": .name(" ")],
                                    folder: "Team", voiceprints: voiceprints)
        let out = root.appendingPathComponent(saved)
        let transcript = readText(out.appendingPathComponent("transcript.md"))
        #expect(transcript.contains("**[00:10] Alex Kim:** Yes.") && transcript.contains("**[00:20] Alex Kim:** Still me."))
        #expect(transcript.contains("**[00:30] Several people:** We agree."))
        #expect(!transcript.contains("Hold music."))
        #expect(transcript.contains("**[00:50] Voice 5:** And me."))
        let meta = try readJSON(MeetingMeta.self, out.appendingPathComponent("meeting.json"))
        #expect(meta.participants == ["Sam Taylor", "Alex Kim", "Voice 5"])
        #expect(readText(out.appendingPathComponent("notes.md")) == "- Agenda\n- [01:05] Budget agreed\n")
        // Only a named person is remembered, by the voice they said most with.
        let people = Voiceprints.load(voiceprints).people
        #expect(Array(people.keys) == ["Alex Kim"] && people["Alex Kim"]?.samples.map(\.embedding) == [[1, 0]])
        // The audio goes unless it's being kept; the folder itself is tidySaved's to clear.
        #expect(FileManager.default.fileExists(atPath: recDir.appendingPathComponent("saved.json").path))
    }
}

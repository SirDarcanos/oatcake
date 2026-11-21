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
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Morning all."), Line(speaker: "A", start: 4, end: 6, text: "Hi John.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "John Doe"
        config.outputDir = root.path
        config.keepAudio = true
        config.llm = LlmConfig(model: LlmConfig.ownServer) // no endpoint: the model can't be reached
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Weekly sync", folder: "", startedAt: Date(), state: .processed)

        let saved = try saveMeeting(config, rec, decisions: ["A": .name("Jane Doe")], folder: "")
        let out = root.appendingPathComponent(saved)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("meeting.json").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
        #expect(readText(out.appendingPathComponent("transcript.md")).contains("**[00:04] Jane Doe:** Hi John."))
        #expect(FileManager.default.fileExists(atPath: recDir.appendingPathComponent("saved.json").path))
        // Writing the summary fails while no model is set up, and leaves the meeting alone.
        await #expect(throws: OatcakeError("Set the endpoint and model in Settings first.")) { try await writeSummary(config, meeting: saved) }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))

        // When the model has answered, its summary goes where the meeting is by then (it was renamed
        // meanwhile), and a to-do added in the meantime is kept above the model's.
        let meetings = Meetings(root: root)
        let renamed = try meetings.retitle(saved, to: "Weekly sync with Jane")
        try meetings.write(renamed, .todo, "- [ ] Added while the model was writing\n")
        try writeSummary(SummaryDraft(summary: "## Topic\nDone.\n", todo: "- [ ] From the model — Jane Doe\n"), config: config, meeting: renamed)
        let files = try meetings.read(renamed)
        #expect(files.summary == "## Topic\nDone.\n")
        #expect(files.todo == "- [ ] Added while the model was writing\n- [ ] From the model — Jane Doe\n")

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
        try meetings.write(rel, .transcript, "**[00:00] John:** A decision.\n")
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

        let path = try saveMeeting(config, rec, decisions: ["A": .name("Jane Doe"), "B": .merge(into: "A")], folder: "", voiceprints: prints)
        #expect(Voiceprints.load(prints).people["Jane Doe"]?.samples.map(\.embedding) == [[1, 0]])
        let files = try Meetings(root: config.meetingsRoot).read(path)
        #expect(files.transcript.hasPrefix("**[00:01] Me:** Morning.") && files.meta.participants == ["Me", "Jane Doe"])
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
        config.myName = "John Doe"
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

        let path = try saveMeeting(config, rec, decisions: ["A": .name("Jane Doe")], folder: "Clients/Acme", title: "  Acme kickoff ")
        #expect(path.hasPrefix("Clients/Acme/") && path.hasSuffix(" Acme kickoff"))
        let files = try Meetings(root: config.meetingsRoot).read(path)
        #expect(files.meta.title == "Acme kickoff")
        let paragraphs = parseTranscript(files.transcript)
        #expect(paragraphs.map(\.speaker) == ["Jane Doe", "Jane Doe", "Jane Doe", "John Doe"])
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
        config.myName = "John Doe"
        config.outputDir = root.path
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Catch-up", folder: "", startedAt: Date(), state: .processed)

        // A isn't on the call, and B is A again.
        let saved = try saveMeeting(config, rec, decisions: ["A": .ignore, "B": .merge(into: "A"), "C": .name("Jane Doe")],
                                    folder: "", voiceprints: voiceprints)
        let out = root.appendingPathComponent(saved)
        let transcript = readText(out.appendingPathComponent("transcript.md"))
        #expect(!transcript.contains("Table for two.") && !transcript.contains("By the window."))
        #expect(transcript.contains("**[00:30] Jane Doe:** Yes, go ahead."))
        let meta = try readJSON(MeetingMeta.self, out.appendingPathComponent("meeting.json"))
        #expect(meta.participants == ["John Doe", "Jane Doe"])
        #expect(Array(Voiceprints.load(voiceprints).people.keys) == ["Jane Doe"])
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
        config.myName = "John Doe"
        config.outputDir = root.path
        let rec = Recording(id: "2026-11-10T14-00-00-000Z", dir: recDir, title: "Planning", folder: "", startedAt: Date(), state: .processed)

        // B is A again; C is several people; D isn't anyone; E was left unnamed.
        let saved = try saveMeeting(config, rec, decisions: ["A": .name("Jane Doe"), "B": .merge(into: "A"), "C": .mixed, "D": .ignore, "E": .name(" ")],
                                    folder: "Team", voiceprints: voiceprints)
        let out = root.appendingPathComponent(saved)
        let transcript = readText(out.appendingPathComponent("transcript.md"))
        #expect(transcript.contains("**[00:10] Jane Doe:** Yes.") && transcript.contains("**[00:20] Jane Doe:** Still me."))
        #expect(transcript.contains("**[00:30] Several people:** We agree."))
        #expect(!transcript.contains("Hold music."))
        #expect(transcript.contains("**[00:50] Voice 5:** And me."))
        let meta = try readJSON(MeetingMeta.self, out.appendingPathComponent("meeting.json"))
        #expect(meta.participants == ["John Doe", "Jane Doe", "Voice 5"])
        #expect(readText(out.appendingPathComponent("notes.md")) == "- Agenda\n- [01:05] Budget agreed\n")
        // Only a named person is remembered, by the voice they said most with.
        let people = Voiceprints.load(voiceprints).people
        #expect(Array(people.keys) == ["Jane Doe"] && people["Jane Doe"]?.samples.map(\.embedding) == [[1, 0]])
        // The audio goes unless it's being kept; the folder itself is tidySaved's to clear.
        #expect(FileManager.default.fileExists(atPath: recDir.appendingPathComponent("saved.json").path))
    }

    /// Saved straight after the call (After a call), a meeting has the voices Oatcake recognised under
    /// their names and every other voice as "Voice N", whatever the model guessed, and remembers no
    /// voices. Naming them later rewrites it where it is now, under the title it has now, with the new
    /// names put into its summary and to-dos and your notes left alone.
    @Test func savedUncheckedThenNamedLater() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        let voiceprints = tmp.appendingPathComponent("voiceprints.json")
        let id = "2026-11-10T14-00-00-000Z"
        let recDir = recordings.appendingPathComponent(id)
        try fm.createDirectory(at: recDir.appendingPathComponent("clips"), withIntermediateDirectories: true)
        try #"{"title":"Planning","folder":"Team","startedAt":"2026-11-10T14:00:00.000Z"}"#.write(to: recDir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
        try Data([1, 2]).write(to: recDir.appendingPathComponent("system.pcm"))
        try Data([1]).write(to: recDir.appendingPathComponent("clips/A-1.wav"))
        let suggested = { (name: String, how: Suggestion.How) in Suggestion(name: name, how: how, detail: "", score: how == .voice ? 0.9 : nil) }
        let analysis = Analysis(title: "Planning", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 2, text: "Shall we start?"), Line(speaker: "A", start: 10, end: 12, text: "Yes."),
                                        Line(speaker: "B", start: 20, end: 22, text: "Agreed."), Line(speaker: "C", start: 30, end: 32, text: "Me too.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 300, embedding: [1, 0], suggestion: suggested("Jane Doe", .voice), quotes: []),
                                           SpeakerInfo(id: "B", seconds: 60, embedding: [0, 1], suggestion: suggested("Jane", .transcript), quotes: []),
                                           SpeakerInfo(id: "C", seconds: 45, embedding: [1, 1], suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        try encodeJSON([Note(at: 65, text: "Budget agreed")]).write(to: recDir.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "John Doe"
        config.outputDir = root.path
        let rec = try #require(Recordings.get(id, recordings: recordings))

        // Recognised by voice: named. Guessed from the conversation, or not at all: a number.
        #expect(suggestedDecisions(analysis) == ["A": .name("Jane Doe"), "B": .name(""), "C": .name("")])
        // A voice match that's only good enough to suggest in review names nobody here, and neither
        // does one from an analysis that kept no score.
        var unsure = analysis
        unsure.speakers[0].suggestion?.score = 0.64
        #expect(suggestedDecisions(unsure)["A"] == .name(""))
        unsure.speakers[0].suggestion?.score = nil
        #expect(suggestedDecisions(unsure)["A"] == .name(""))
        // A voice you named during the call is named: you said who it was.
        var named = analysis
        named.speakers[1].suggestion = suggested("John Smith", .live)
        #expect(suggestedDecisions(named)["B"] == .name("John Smith"))
        let saved = try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: "Team", title: rec.title,
                                    unchecked: true, voiceprints: voiceprints)
        let meetings = Meetings(root: root)
        #expect(try meetings.read(saved).transcript.contains("**[00:10] Jane Doe:** Yes.\n\n**[00:20] Voice 2:** Agreed.\n\n**[00:30] Voice 3:** Me too."))
        #expect(Recordings.savedInfo(recDir)?.names == ["A": "Jane Doe", "B": "Voice 2", "C": "Voice 3"])
        #expect(try meetings.read(saved).meta.recording == id)
        // Nobody checked these names, so no voice is remembered; the clips stay to be played, the tracks go.
        #expect(Voiceprints.load(voiceprints).people.isEmpty)
        #expect(fm.fileExists(atPath: recDir.appendingPathComponent("clips/A-1.wav").path))
        #expect(!fm.fileExists(atPath: recDir.appendingPathComponent("system.pcm").path))
        #expect(Recordings.unchecked(recordings: recordings).map(\.id) == [id])
        // Clearing away saved recordings leaves this one: its voices can still be named.
        Recordings.tidySaved(meetingsRoot: root, recordings: recordings)
        #expect(fm.fileExists(atPath: recDir.appendingPathComponent("analysis.json").path))

        // Meanwhile: summarised, retitled (so moved), and its notes and to-dos edited.
        try meetings.write(saved, .summary, "## Budget\n- Voice 2 and Voice 3 agreed it. Jane and Voice 30 weren't there.\n")
        try meetings.write(saved, .todo, "- [ ] Send the figures — Voice 3\n")
        let moved = try meetings.retitle(saved, to: "Budget planning")
        try meetings.write(moved, .notes, "- My own edit\n")

        // Named: B is Jane Smith, C is Jane Doe again.
        let rec2 = try #require(Recordings.get(id, recordings: recordings))
        #expect(Recordings.meetingPath(rec2, meetingsRoot: root) == moved)
        let updated = try saveMeeting(config, rec2, decisions: ["A": .name("Jane Doe"), "B": .name("Jane Smith"), "C": .merge(into: "A")],
                                      folder: "", into: moved, voiceprints: voiceprints)
        #expect(updated == moved)
        let files = try meetings.read(moved)
        #expect(files.transcript.contains("**[00:20] Jane Smith:** Agreed.\n\n**[00:30] Jane Doe:** Me too."))
        // Each number was one voice, so it's swapped exactly; a "Jane" who was only talked about is left alone.
        #expect(files.summary == "## Budget\n- Jane Smith and Jane Doe agreed it. Jane and Voice 30 weren't there.\n")
        #expect(files.todo == "- [ ] Send the figures — Jane Doe\n")
        #expect(files.notes == "- My own edit\n")
        #expect(files.meta.title == "Budget planning" && files.meta.participants == ["John Doe", "Jane Doe", "Jane Smith"])
        // Checked now: the named voices are remembered, and the working folder can go.
        #expect(Set(Voiceprints.load(voiceprints).people.keys) == ["Jane Doe", "Jane Smith"])
        #expect(Recordings.unchecked(recordings: recordings).isEmpty)
        Recordings.tidySaved(meetingsRoot: root, recordings: recordings)
        #expect(!fm.fileExists(atPath: recDir.path))
    }

    /// Keep as is: the meeting stays as it was saved, and its recording is cleared away like any other.
    @Test func uncheckedKeptAsIs() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        let id = "2026-11-10T15-00-00-000Z"
        let recDir = recordings.appendingPathComponent(id)
        try fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        try #"{"title":"Sync","startedAt":"2026-11-10T15:00:00.000Z"}"#.write(to: recDir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
        let analysis = Analysis(title: "Sync", startedAt: "2026-11-10T15:00:00.000Z", endedAt: "2026-11-10T15:10:00.000Z",
                                lines: [Line(speaker: "A", start: 1, end: 2, text: "Hi.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.outputDir = root.path
        let rec = try #require(Recordings.get(id, recordings: recordings))
        let saved = try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: "", unchecked: true,
                                    voiceprints: tmp.appendingPathComponent("voiceprints.json"))
        try Recordings.markChecked(rec)
        #expect(Recordings.unchecked(recordings: recordings).isEmpty)
        #expect(Recordings.savedInfo(recDir) == SavedInfo(meeting: saved))
        Recordings.tidySaved(meetingsRoot: root, recordings: recordings)
        #expect(!fm.fileExists(atPath: recDir.path))
        #expect(try Meetings(root: root).read(saved).transcript.contains("Voice 1:** Hi."))
    }

    /// Two voices recognised as the same person, and so saved under one name, that turn out to be two
    /// people: the transcript knows which is which, but a sentence in the summary doesn't, so that name
    /// is left there. A voice left with its name isn't touched either.
    @Test func oneNameForTwoVoicesIsLeftInTheSummary() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        let id = "2026-11-10T16-00-00-000Z"
        let recDir = recordings.appendingPathComponent(id)
        try fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        try #"{"title":"Sync","startedAt":"2026-11-10T16:00:00.000Z"}"#.write(to: recDir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
        let voice = { (id: String, name: String) in SpeakerInfo(id: id, seconds: 60, embedding: nil, suggestion: Suggestion(name: name, how: .voice, detail: "", score: 0.9), quotes: []) }
        let analysis = Analysis(title: "Sync", startedAt: "2026-11-10T16:00:00.000Z", endedAt: "2026-11-10T16:10:00.000Z",
                                lines: [Line(speaker: "A", start: 1, end: 2, text: "Hi."), Line(speaker: "B", start: 5, end: 6, text: "Hello."),
                                        Line(speaker: "C", start: 9, end: 10, text: "Morning.")],
                                speakers: [voice("A", "Jane Doe"), voice("B", "Jane Doe"), voice("C", "Jane Smith")],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.outputDir = root.path
        let voiceprints = tmp.appendingPathComponent("voiceprints.json")
        let rec = try #require(Recordings.get(id, recordings: recordings))
        let saved = try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: "", unchecked: true, voiceprints: voiceprints)
        let meetings = Meetings(root: root)
        try meetings.write(saved, .summary, "Jane Doe opened. Jane Smith agreed.\n")

        try saveMeeting(config, try #require(Recordings.get(id, recordings: recordings)),
                        decisions: ["A": .name("Jane Doe"), "B": .name("John Smith"), "C": .name("Jane Smith")], folder: "", into: saved, voiceprints: voiceprints)
        let files = try meetings.read(saved)
        #expect(files.transcript.contains("**[00:01] Jane Doe:** Hi.\n\n**[00:05] John Smith:** Hello.\n\n**[00:09] Jane Smith:** Morning."))
        #expect(files.summary == "Jane Doe opened. Jane Smith agreed.\n")
    }

    /// A voice left out when the voices are named later: its lines leave the transcript and its to-dos
    /// go with it, the other to-dos stay as they are (ticked or not), and the app is told the summary
    /// needs writing again, because what it says of that voice can't be cut out of it.
    @Test func voiceLeftOutLater() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        let voiceprints = tmp.appendingPathComponent("voiceprints.json")
        let id = "2026-11-10T17-00-00-000Z"
        let recDir = recordings.appendingPathComponent(id)
        try fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        try #"{"title":"Suppliers","folder":"","startedAt":"2026-11-10T17:00:00.000Z"}"#.write(to: recDir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
        let speaker = { (id: String) in SpeakerInfo(id: id, seconds: 60, embedding: nil, suggestion: nil, quotes: []) }
        let analysis = Analysis(title: "Suppliers", startedAt: "2026-11-10T17:00:00.000Z", endedAt: "2026-11-10T17:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 2, text: "Shall we start?"), Line(speaker: "A", start: 10, end: 12, text: "Two left."),
                                        Line(speaker: "B", start: 20, end: 22, text: "A table for four."), Line(speaker: "C", start: 30, end: 32, text: "Same here.")],
                                speakers: [speaker("A"), speaker("B"), speaker("C")],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "John Doe"
        config.outputDir = root.path
        let rec = try #require(Recordings.get(id, recordings: recordings))
        let saved = try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: "", unchecked: true, voiceprints: voiceprints)
        let meetings = Meetings(root: root)
        try meetings.write(saved, .summary, "- Voice 1 has two left. Voice 2 asked for a table.\n")
        try meetings.write(saved, .todo, "- [x] Ask for references — Voice 1\n- [ ] Book a table — Voice 2 — due Friday\n- [ ] Call the bank\n- [ ] Send the numbers — Voice 3\n")

        // Naming alone leaves nobody out; leaving out B does, and so does leaving out a voice B was merged into.
        let rec2 = try #require(Recordings.get(id, recordings: recordings))
        #expect(!leavesOutSavedVoice(rec2, ["A": .name("Jane Doe"), "B": .mixed, "C": .merge(into: "A")]))
        #expect(leavesOutSavedVoice(rec2, ["A": .ignore, "B": .merge(into: "A"), "C": .name("")]))
        let decisions: [String: Decision] = ["A": .name("Jane Doe"), "B": .ignore, "C": .name("Jane Smith")]
        #expect(leavesOutSavedVoice(rec2, decisions))
        _ = try saveMeeting(config, rec2, decisions: decisions, folder: "", into: saved, voiceprints: voiceprints)
        let files = try meetings.read(saved)
        #expect(!files.transcript.contains("A table for four.") && files.meta.participants == ["John Doe", "Jane Doe", "Jane Smith"])
        #expect(files.todo == "- [x] Ask for references — Jane Doe\n- [ ] Call the bank\n- [ ] Send the numbers — Jane Smith\n")
        // The summary has its names put in; the rest of it is the app's to have written again.
        #expect(files.summary == "- Jane Doe has two left. Voice 2 asked for a table.\n")
        // Checked now, so there's nothing on record to leave a voice out of.
        #expect(!leavesOutSavedVoice(try #require(Recordings.get(id, recordings: recordings)), decisions))
    }

    /// Naming a meeting's voices later writes its meeting.json again, and keeps the summary template
    /// it was regenerated with.
    @Test func templateSurvivesNamingLater() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        let voiceprints = tmp.appendingPathComponent("voiceprints.json")
        let id = "2026-11-10T18-00-00-000Z"
        let recDir = recordings.appendingPathComponent(id)
        try fm.createDirectory(at: recDir, withIntermediateDirectories: true)
        try #"{"title":"One-to-one","folder":"","startedAt":"2026-11-10T18:00:00.000Z"}"#.write(to: recDir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
        let analysis = Analysis(title: "One-to-one", startedAt: "2026-11-10T18:00:00.000Z", endedAt: "2026-11-10T18:30:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 2, text: "How's it going?"), Line(speaker: "A", start: 5, end: 7, text: "Busy week.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 60, embedding: nil, suggestion: nil, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        var config = Config.defaults()
        config.myName = "John Doe"
        config.outputDir = root.path
        let rec = try #require(Recordings.get(id, recordings: recordings))
        let saved = try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: "", unchecked: true, voiceprints: voiceprints)
        let meetings = Meetings(root: root)
        try meetings.setSummaryTemplate(saved, "1:1 I lead")
        _ = try saveMeeting(config, try #require(Recordings.get(id, recordings: recordings)), decisions: ["A": .name("Jane Doe")],
                            folder: "", into: saved, voiceprints: voiceprints)
        let meta = try meetings.read(saved).meta
        #expect(meta.template == "1:1 I lead" && meta.participants == ["John Doe", "Jane Doe"] && meta.recording == id)
    }

    /// A meeting saved without checking that has since gone (to the Trash, say) takes its recording's
    /// clips and analysis with it at the next clear-up. A Meetings folder that isn't there at all (a
    /// drive that's unplugged) says nothing about one meeting, so nothing is cleared.
    @Test func uncheckedRecordingGoesWithItsMeeting() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oatcake-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let recordings = tmp.appendingPathComponent("recordings"), root = tmp.appendingPathComponent("Meetings")
        var config = Config.defaults()
        config.outputDir = root.path
        func savedUnchecked(_ id: String) throws -> (dir: URL, meeting: String) {
            let recDir = recordings.appendingPathComponent(id)
            try fm.createDirectory(at: recDir.appendingPathComponent("clips"), withIntermediateDirectories: true)
            try #"{"title":"Sync","startedAt":"2026-11-10T15:00:00.000Z"}"#.write(to: recDir.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)
            try Data([1]).write(to: recDir.appendingPathComponent("clips/A-1.wav"))
            let analysis = Analysis(title: "Sync", startedAt: "2026-11-10T15:00:00.000Z", endedAt: "2026-11-10T15:10:00.000Z",
                                    lines: [Line(speaker: "A", start: 1, end: 2, text: "Hi.")],
                                    speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: [])],
                                    echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
            try encodeJSON(analysis).write(to: recDir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
            let rec = try #require(Recordings.get(id, recordings: recordings))
            return (recDir, try saveMeeting(config, rec, decisions: suggestedDecisions(analysis), folder: "", unchecked: true,
                                            voiceprints: tmp.appendingPathComponent("voiceprints.json")))
        }
        let gone = try savedUnchecked("2026-11-10T15-00-00-000Z"), kept = try savedUnchecked("2026-11-10T15-00-01-000Z")
        #expect(gone.meeting != kept.meeting)

        // The Meetings folder can't be found: both stay.
        Recordings.tidySaved(meetingsRoot: tmp.appendingPathComponent("Unplugged"), recordings: recordings)
        #expect(fm.fileExists(atPath: gone.dir.path) && fm.fileExists(atPath: kept.dir.path))

        // One meeting is deleted: its recording goes, the other's clips stay to be named.
        try fm.removeItem(at: root.appendingPathComponent(gone.meeting))
        Recordings.tidySaved(meetingsRoot: root, recordings: recordings)
        #expect(!fm.fileExists(atPath: gone.dir.path))
        #expect(fm.fileExists(atPath: kept.dir.appendingPathComponent("clips/A-1.wav").path))
        #expect(Recordings.unchecked(recordings: recordings).map(\.id) == ["2026-11-10T15-00-01-000Z"])
    }

    /// New names go in as whole words, and names that swap places don't run into each other.
    @Test func renamingPeople() {
        #expect(renamePeople("Voice 1 and Voice 12 met Voice 1.", ["Voice 1": "Jane Roe"]) == "Jane Roe and Voice 12 met Jane Roe.")
        #expect(renamePeople("John told Johnny.", ["John": "Johnny", "Johnny": "John"]) == "Johnny told John.")
        #expect(renamePeople("Several people agreed.", ["Several people": "Jane Roe"]) == "Several people agreed.")
        #expect(renamePeople("(Voice 2) owns it", ["Voice 2": "Jane Roe (PM)"]) == "(Jane Roe (PM)) owns it")
    }
}

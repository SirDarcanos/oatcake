import Foundation
@testable import OatcakeCore
import Testing

/// Rename speakers… in a saved meeting.
@Suite struct SpeakerNamesTests {
    let transcript = """
        **[00:05] Tester:** Hi Alex, hi Sam.

        **[00:09] Alex:** Hi. Sam and I looked at the budget.

        **[00:20] Several people:** (laughter)

        **[00:31] Sam:** Alex will send it Friday.

        **[01:02] Alex:** I'll send it.

        """

    private func meeting(_ meta: String = #"{"title": "Weekly", "participants": ["Tester", "Alex", "Sam"], "recording": "rec-1"}"#) throws -> (TestMeetings, Meetings) {
        let m = TestMeetings()
        try m.write("Team/2026-11-19 1000 Weekly", .transcript, transcript, meta: meta)
        try m.write("Team/2026-11-19 1000 Weekly", .summary, "## Budget\n- Alex and Sam looked at the budget.\n")
        try m.write("Team/2026-11-19 1000 Weekly", .todo, "- [ ] Send the budget — Alex — due Friday — [00:31]\n")
        return (m, Meetings(root: m.root))
    }

    private func sample(_ embedding: [Float], _ call: String, _ at: String = "2026-11-01T10:00:00.000Z") -> Voiceprints.Sample {
        .init(embedding: embedding, call: call, at: at)
    }

    /// The speakers in the order they first speak, with how much they said and their first words;
    /// "Several people" isn't one, and an imported transcript (Granola's) has none to rename.
    @Test func listsTheSpeakers() {
        let found = meetingSpeakers(transcript)
        #expect(found.map(\.name) == ["Tester", "Alex", "Sam"])
        #expect(found[1].paragraphs == 2 && found[1].firstAt == "00:09" && found[1].firstWords == "Hi. Sam and I looked at the budget.")
        #expect(meetingSpeakers("[00:05] System audio (Alex): Hello\n[00:09] Microphone: Hi\n").isEmpty)
    }

    /// Two names swap: the labels, the summary and the to-dos change, never what was said.
    @Test func swapsNamesInThisMeetingOnly() throws {
        let (m, meetings) = try meeting(#"{"title": "Weekly", "participants": ["Tester", "Alex", "Sam"]}"#)
        defer { m.remove() }
        let rel = "Team/2026-11-19 1000 Weekly"
        try meetings.renameSpeakers(rel, ["Alex": "Sam", "Sam": "Alex", "Tester": "  "], me: "Tester",
                                    voiceprints: m.root.appendingPathComponent("voiceprints.json"))
        let files = try meetings.read(rel)
        #expect(files.transcript.contains("**[00:09] Sam:** Hi. Sam and I looked at the budget."))
        #expect(files.transcript.contains("**[00:31] Alex:** Alex will send it Friday."))
        #expect(files.transcript.contains("**[00:05] Tester:** Hi Alex, hi Sam."))
        #expect(files.transcript.contains("**[00:20] Several people:**"))
        #expect(files.summary == "## Budget\n- Sam and Alex looked at the budget.\n")
        #expect(files.todo == "- [ ] Send the budget — Sam — due Friday — [00:31]\n")
        #expect(files.meta.participants == ["Tester", "Sam", "Alex"])
        // A meeting with no recording (an import) has no fingerprint to move.
        #expect(!FileManager.default.fileExists(atPath: m.root.appendingPathComponent("voiceprints.json").path))
    }

    /// A name given to someone already in the meeting makes them one speaker. "Several people" isn't renamed.
    @Test func mergesIntoAnotherSpeaker() throws {
        let (m, meetings) = try meeting()
        defer { m.remove() }
        let rel = "Team/2026-11-19 1000 Weekly"
        try meetings.renameSpeakers(rel, ["Alex": "Sam", "Several people": "Bea"], me: "Tester",
                                    voiceprints: m.root.appendingPathComponent("voiceprints.json"))
        let files = try meetings.read(rel)
        #expect(meetingSpeakers(files.transcript).map(\.name) == ["Tester", "Sam"])
        #expect(files.transcript.contains("**[00:20] Several people:**"))
        #expect(files.meta.participants == ["Tester", "Sam"])
    }

    /// The fingerprint saved from this call under the wrong name goes to the right one; the old
    /// name's other calls, and everyone else's fingerprints, stay as they were.
    @Test func movesThisCallsFingerprint() throws {
        let (m, meetings) = try meeting()
        defer { m.remove() }
        let file = m.root.appendingPathComponent("voiceprints.json")
        try Voiceprints(model: voiceprintModel, people: [
            "Alex": .init(samples: [sample([1, 0, 0], "earlier"), sample([0, 1, 0], "rec-1")]),
            "Bea": .init(samples: [sample([0, 0, 1], "rec-1"), sample([0, 0, 1], "other")]),
        ]).save(file)
        try meetings.renameSpeakers("Team/2026-11-19 1000 Weekly", ["Alex": "Sam"], me: "Tester", voiceprints: file)
        let prints = Voiceprints.load(file)
        #expect(prints.people["Alex"]?.samples.map(\.call) == ["earlier"])
        #expect(prints.people["Sam"]?.samples.map(\.call) == ["rec-1"])
        #expect(prints.people["Sam"]?.samples.first?.embedding == [0, 1, 0])
        #expect(prints.people["Bea"]?.samples.map(\.call) == ["rec-1", "other"])
    }

    /// When the old name's other calls sound the same, the voice was theirs and only the name was
    /// written differently here: the fingerprint stays. "Voice 2" isn't a name to remember, so a
    /// fingerprint renamed to it is dropped, and a person left with none is forgotten.
    @Test func keepsOrDropsFingerprints() throws {
        let (m, meetings) = try meeting()
        defer { m.remove() }
        let file = m.root.appendingPathComponent("voiceprints.json")
        try Voiceprints(model: voiceprintModel, people: [
            "Alex": .init(samples: [sample([1, 0, 0], "earlier"), sample([0.98, 0.2, 0], "rec-1")]),
            "Sam": .init(samples: [sample([0, 1, 0], "rec-1")]),
        ]).save(file)
        try meetings.renameSpeakers("Team/2026-11-19 1000 Weekly", ["Alex": "Alex Smith", "Sam": "Voice 2"], me: "Tester", voiceprints: file)
        let prints = Voiceprints.load(file)
        #expect(prints.people["Alex"]?.samples.map(\.call) == ["earlier", "rec-1"])
        #expect(prints.people["Alex Smith"] == nil)
        #expect(prints.people["Sam"] == nil && prints.people["Voice 2"] == nil)
    }

    /// A wrong name that came from a voice suggestion: this call's fingerprint was close to the old
    /// name's other calls (0.65, above the 0.6 that review suggests at), and so is a near match
    /// under an unrelated name. Both move: only a respelling of the same name keeps one in place.
    @Test func movesAWrongNameFromAVoiceSuggestion() throws {
        let (m, meetings) = try meeting()
        defer { m.remove() }
        let file = m.root.appendingPathComponent("voiceprints.json")
        try Voiceprints(model: voiceprintModel, people: [
            "Alex": .init(samples: [sample([1, 0, 0], "earlier"), sample([0.65, 0.76, 0], "rec-1")]),
            "Sam": .init(samples: [sample([0, 0, 1], "earlier"), sample([0.2, 0, 0.98], "rec-1")]),
        ]).save(file)
        try meetings.renameSpeakers("Team/2026-11-19 1000 Weekly", ["Alex": "Bea", "Sam": "Cal"], me: "Tester", voiceprints: file)
        let prints = Voiceprints.load(file)
        #expect(prints.people["Alex"]?.samples.map(\.call) == ["earlier"])
        #expect(prints.people["Bea"]?.samples.map(\.call) == ["rec-1"])
        #expect(prints.people["Sam"]?.samples.map(\.call) == ["earlier"])
        #expect(prints.people["Cal"]?.samples.map(\.call) == ["rec-1"])
    }
}

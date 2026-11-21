import Foundation
@testable import OatcakeCore
import Testing

@Suite struct LiveVoicesTests {
    /// A made-up fingerprint: mostly one direction of its own, with some of another for a voice that
    /// doesn't sound quite the same every time.
    private func voice(_ own: Int, _ other: Int? = nil, by amount: Float = 0.3) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[own] = 1
        if let other { v[other] += amount }
        return normalise(v)
    }

    private func known(_ people: [String: [Float]]) -> Voiceprints {
        Voiceprints(model: voiceprintModel, people: people.mapValues { .init(samples: [.init(embedding: $0, call: "earlier", at: "2026-11-01T10:00:00Z")]) })
    }

    /// People Oatcake knows by voice are named as review would suggest them: a clear match, ahead of
    /// anyone else. A voice nobody knows, and one that sounds like two people, stay unnamed.
    @Test func knownVoicesAreNamed() {
        let prints = known(["John Doe": voice(0), "Jane Doe": voice(1)])
        let lines = [LiveVoice(line: "a", embedding: voice(0, 2), known: prints),
                     LiveVoice(line: "b", embedding: voice(3), known: prints),
                     LiveVoice(line: "c", embedding: voice(0, 1, by: 1), known: prints)]
        #expect(nameLiveVoices(lines, named: [:]) == ["a": "John Doe"])
    }

    /// A line you name is that person's, whoever it sounds like, and their other lines follow it:
    /// before it as well as after. Someone else's don't. Here it sounded like John Doe, whom Oatcake
    /// knows: you've said it isn't them, so their kept fingerprints don't name anyone in this call.
    @Test func aNamedLineIsFollowed() {
        let prints = known(["John Doe": voice(4)])
        let lines = [LiveVoice(line: "earlier", embedding: voice(4, 5), known: prints),
                     LiveVoice(line: "named", embedding: voice(4), known: prints),
                     LiveVoice(line: "later", embedding: voice(4, 6), known: prints),
                     LiveVoice(line: "someone else", embedding: voice(7), known: prints)]
        #expect(nameLiveVoices(lines, named: ["named": "Jane Smith"]) == ["earlier": "Jane Smith", "named": "Jane Smith", "later": "Jane Smith"])
    }

    /// A voice is followed by its lines so far, averaged: a line too far from the one you named is
    /// still theirs once the lines between have shown the way their voice goes.
    @Test func linesSoFarAreAveraged() {
        let none = known([:])
        let named = LiveVoice(line: "named", embedding: voice(4), known: none)
        let between = LiveVoice(line: "between", embedding: voice(4, 5, by: 0.9), known: none)
        let far = LiveVoice(line: "far", embedding: voice(5, 4, by: 0.5), known: none)
        #expect(nameLiveVoices([named, far], named: ["named": "Jane Doe"])["far"] == nil)
        #expect(nameLiveVoices([named, between, far], named: ["named": "Jane Doe"])["far"] == "Jane Doe")
    }

    /// After the call, a voice starts Who's who with the name you gave the lines it said most of. A
    /// line two voices shared counts for neither.
    @Test func namesCarryToWhosWho() {
        let turns = [Turn(start: 0, end: 10, speaker: "S1"), Turn(start: 10, end: 20, speaker: "S2"), Turn(start: 20, end: 30, speaker: "S1")]
        let letters = ["S1": "A", "S2": "B"]
        func named(_ start: Double, _ end: Double, _ name: String) -> LiveName {
            LiveName(line: LiveTranscriptLine(track: .system, start: start, end: end, text: "…"), name: name)
        }
        let given = [named(1, 8, "Jane Doe"), named(8, 12, "John Doe"), named(21, 29, "Jane Doe"), named(11, 19, "John Smith"), named(12, 13, "John Doe")]
        let live = { (name: String) in Suggestion(name: name, how: .live, detail: "") }
        #expect(liveNameSuggestions(given, turns: turns, letters: letters) == ["A": live("Jane Doe"), "B": live("John Smith")])
        // Nobody told apart: the call audio is one voice.
        #expect(liveNameSuggestions([named(0, 5, "Jane Doe")], turns: [], letters: [:]) == ["A": live("Jane Doe")])
    }

    /// The names you give are kept in the recording, line by line, and an older live line (without a
    /// speaker) still reads.
    @Test func namesAreKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LiveNames.load(dir).isEmpty)
        let line = LiveTranscriptLine(track: .system, start: 12.5, end: 15, text: "Morning.")
        try LiveNames.save([LiveName(line: line, name: "Jane Doe")], in: dir)
        #expect(LiveNames.load(dir) == [LiveName(line: line, name: "Jane Doe")])
        #expect(LiveNames.load(dir).first?.line == "system 12.5")
        let old = try JSONDecoder().decode(LiveTranscriptLine.self, from: Data(#"{"track":"system","start":1,"end":2,"text":"Hi."}"#.utf8))
        #expect(old.speaker == nil)
    }
}

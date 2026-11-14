import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct AnalysisTests {
    @Test func echo() {
        let system = [Line(speaker: "A", start: 10, end: 14, text: "I think that's fine, do you agree?")]
        #expect(isEcho(Line(speaker: me, start: 11, end: 13, text: "I think that's fine"), system))
        #expect(!isEcho(Line(speaker: me, start: 15, end: 16, text: "Yes, I agree that's fine"), system))
        #expect(!isEcho(Line(speaker: me, start: 40, end: 42, text: "I think that's fine"), system))
    }

    @Test func splitsBySpeaker() {
        let words = [Word(text: "Hello", start: 0, end: 0.5), Word(text: "there.", start: 0.5, end: 1), Word(text: "Hi", start: 2.1, end: 2.4), Word(text: "!", start: 2.4, end: 2.5)]
        let turns = [Turn(start: 0, end: 1.5, speaker: "S2"), Turn(start: 2, end: 3, speaker: "S1")]
        let letters = speakerLetters(turns)
        #expect(letters == ["S2": "A", "S1": "B"])
        let lines = splitBySpeaker(Utterance(start: 0, end: 2.5, text: "Hello there. Hi!", words: words), turns: turns, letters: letters)
        #expect(lines.map(\.speaker) == ["A", "B"])
        #expect(lines.map(\.text) == ["Hello there.", "Hi!"])
    }

    /// A name is only suggested when it was said: a small model asked for one will sometimes invent it.
    @Test func suggestedNames() async throws {
        let transcript = "Sam Taylor (recorder): Priya, where are we with pricing?\nSpeaker A: Nearly there.\nSpeaker B: I agree with Priya."
        let reply = #"{"speakers":[{"speaker":"Speaker A","name":"Priya","quote":"Priya, where are we"},{"speaker":"B","name":"Jordan Lee","quote":null},{"speaker":"C","name":"Sam","quote":"x"},{"speaker":"Z","name":"Priya","quote":"x"}]}"#
        let names = namesIn(reply, unknown: ["A", "B", "C"], transcript: transcript, myName: "Sam Taylor")
        // B's name was never said, C's is your own, and Z wasn't asked about.
        #expect(names == ["A": Suggestion(name: "Priya", how: .transcript, detail: "Priya, where are we")])
        #expect(namesIn(#"{"speakers":[{"speaker":"A","name":"null","quote":"null"},{"speaker":"B","name":"Speaker B","quote":null}]}"#, unknown: ["A", "B"], transcript: transcript, myName: "Sam Taylor").isEmpty)
        // Said means said as a word: "Dan" isn't in "abundant", and "Ann" isn't in "announce". A name in two parts is.
        let said = "Sam Taylor (recorder): Jean-Luc, the evidence is abundant.\nSpeaker A: I will announce it.\nSpeaker B: Fine."
        let made = #"{"speakers":[{"speaker":"A","name":"Dan","quote":null},{"speaker":"B","name":"Ann","quote":null},{"speaker":"C","name":"Jean-Luc","quote":"Jean-Luc, the evidence"}]}"#
        #expect(namesIn(made, unknown: ["A", "B", "C"], transcript: said, myName: "Sam Taylor").mapValues(\.name) == ["C": "Jean-Luc"])

        // From a processed recording: the voice nobody recognised gets its name, one that was recognised keeps its own.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = Suggestion(name: "Alex Kim", how: .voice, detail: "voice match 0.81")
        let analysis = Analysis(title: "Pricing", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Priya, where are we with pricing?"), Line(speaker: "A", start: 4, end: 6, text: "Nearly there."),
                                        Line(speaker: "B", start: 7, end: 9, text: "Good.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: []),
                                           SpeakerInfo(id: "B", seconds: 30, embedding: nil, suggestion: known, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        #expect(hasUnnamedVoices(dir))
        let server = try await StandIn.model { _ in #"{"speakers":[{"speaker":"A","name":"Priya","quote":"Priya, where are we"},{"speaker":"B","name":"Priya","quote":null}]}"# }
        await suggestNames(dir, config: server.config)
        let named = try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json"))
        #expect(named.speakers.map(\.suggestion?.name) == ["Priya", "Alex Kim"] && named.warnings.isEmpty && !hasUnnamedVoices(dir))
        let asked = try #require(server.requests.first)
        #expect(asked.messages.user.contains("Sam Taylor (recorder): Priya, where are we with pricing?\nSpeaker A: Nearly there.\nAlex Kim: Good."))
        #expect(asked.messages.user.contains("Unidentified speakers: Speaker A\n") && asked.json["response_format"] != nil)
        #expect(asked.json["temperature"] as? Double == 0.6)

        // The model is shown "Alex Kim:" before the recognised voice's lines. That's a label, not something
        // said: it doesn't make Alex Kim a name the other voice can be given.
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let echoes = try await StandIn.model { _ in #"{"speakers":[{"speaker":"A","name":"Alex Kim","quote":null}]}"# }
        await suggestNames(dir, config: echoes.config)
        #expect(try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json")).speakers.map(\.suggestion?.name) == [nil, "Alex Kim"])

        // A model that can't be reached is noted for the review screen, and the analysis is left as it was.
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let broken = try await StandIn { _ in StandIn.Response(status: 500, body: Data("no".utf8)) }
        await suggestNames(dir, config: broken.config)
        let skipped = try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json"))
        #expect(skipped.speakers[0].suggestion == nil && skipped.warnings.first?.hasPrefix("Name suggestions skipped: ") == true)
    }

    /// What the helpers print for the app, a line at a time: each survives the trip, and a line that
    /// says only some of it reads with the rest left out.
    @Test func linesFromTheHelpers() throws {
        func line(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        let step = try JSONDecoder().decode(AnalysisProgress.self, from: Data(try line(AnalysisProgress(step: analysisSteps[1], fraction: 0.5)).utf8))
        #expect(step == AnalysisProgress(step: "Transcribing the call audio", fraction: 0.5))
        #expect(!(try line(AnalysisProgress(done: true))).contains("\n"))
        #expect(try JSONDecoder().decode(AnalysisProgress.self, from: Data(#"{"done":true}"#.utf8)) == AnalysisProgress(done: true))
        #expect(try JSONDecoder().decode(AnalysisProgress.self, from: Data(#"{"error":"No such file"}"#.utf8)).error == "No such file")
        #expect((try? JSONDecoder().decode(AnalysisProgress.self, from: Data("Loading model…".utf8))) == nil)

        let said = LiveTranscriptLine(track: .system, start: 12.5, end: 14, text: "Shall we start?")
        let event = try JSONDecoder().decode(LiveEvent.self, from: Data(try line(LiveEvent(line: said)).utf8))
        #expect(event.line == said && event.status == nil && event.error == nil)
        #expect(try JSONDecoder().decode(LiveEvent.self, from: Data(#"{"status":"Listening"}"#.utf8)).status == "Listening")
        #expect(try JSONDecoder().decode(LiveEvent.self, from: Data(#"{"error":"The speech models couldn’t be loaded"}"#.utf8)).error != nil)
    }

    /// A call with more voices than letters doesn't give two of them the same one.
    @Test func lettersPastZ() {
        #expect([0, 1, 25, 26, 27, 51, 52, 701, 702].map(speakerLetter) == ["A", "B", "Z", "AA", "AB", "AZ", "BA", "ZZ", "AAA"])
        let turns = (0..<30).map { Turn(start: Double($0), end: Double($0) + 0.5, speaker: "s\($0)") }
        let letters = speakerLetters(turns)
        #expect(Set(letters.values).count == 30 && letters["s0"] == "A" && letters["s26"] == "AA")
    }
}

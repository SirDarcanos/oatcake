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

        // Chinese has no spaces between words: its characters are compared, so an echo the mic heard
        // a little differently is still one, and a reply isn't.
        #expect(words("大家早上好，Oatcake 3.0") == ["大", "家", "早", "上", "好", "oatcake", "3", "0"])
        let call = [Line(speaker: "A", start: 10, end: 14, text: "大家早上好，我们先快速过一下进度。")]
        #expect(isEcho(Line(speaker: me, start: 11, end: 13, text: "大家早上好我们先快速过一下进展"), call))
        #expect(!isEcho(Line(speaker: me, start: 15, end: 16, text: "好的，我同意。"), call))
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
        let transcript = "John Doe (recorder): Joe Bloggs, where are we with pricing?\nSpeaker A: Nearly there.\nSpeaker B: I agree with Joe Bloggs."
        let reply = #"{"speakers":[{"speaker":"Speaker A","name":"Joe Bloggs","quote":"Joe Bloggs, where are we"},{"speaker":"B","name":"Richard Roe","quote":null},{"speaker":"C","name":"John","quote":"x"},{"speaker":"Z","name":"Joe Bloggs","quote":"x"}]}"#
        let names = namesIn(reply, unknown: ["A", "B", "C"], transcript: transcript, myName: "John Doe")
        // B's name was never said, C's is your own, and Z wasn't asked about.
        #expect(names == ["A": Suggestion(name: "Joe Bloggs", how: .transcript, detail: "Joe Bloggs, where are we")])
        #expect(namesIn(#"{"speakers":[{"speaker":"A","name":"null","quote":"null"},{"speaker":"B","name":"Speaker B","quote":null}]}"#, unknown: ["A", "B"], transcript: transcript, myName: "John Doe").isEmpty)
        // Said means said as a word: "Smith" isn't in "blacksmith", and "Roe" isn't in "throes". A name in two parts is.
        let said = "John Doe (recorder): Joe Bloggs, the blacksmith is here.\nSpeaker A: The work is in its final throes.\nSpeaker B: Fine."
        let made = #"{"speakers":[{"speaker":"A","name":"Smith","quote":null},{"speaker":"B","name":"Roe","quote":null},{"speaker":"C","name":"Joe Bloggs","quote":"Joe Bloggs, the blacksmith"}]}"#
        #expect(namesIn(made, unknown: ["A", "B", "C"], transcript: said, myName: "John Doe").mapValues(\.name) == ["C": "Joe Bloggs"])
        // Chinese and Japanese names have no spaces around them: said as written is enough.
        let chinese = "John Doe (recorder): 张三，定价怎么样了？\nSpeaker A: 快好了。"
        let guessed = #"{"speakers":[{"speaker":"A","name":"张三","quote":"张三，定价"},{"speaker":"B","name":"李四","quote":null}]}"#
        #expect(namesIn(guessed, unknown: ["A", "B"], transcript: chinese, myName: "John Doe").mapValues(\.name) == ["A": "张三"])

        // From a processed recording: the voice nobody recognised gets its name, one that was recognised keeps its own.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = Suggestion(name: "Jane Doe", how: .voice, detail: "voice match 0.81")
        let analysis = Analysis(title: "Pricing", startedAt: "2026-11-10T14:00:00.000Z", endedAt: "2026-11-10T14:25:00.000Z",
                                lines: [Line(speaker: me, start: 1, end: 3, text: "Joe Bloggs, where are we with pricing?"), Line(speaker: "A", start: 4, end: 6, text: "Nearly there."),
                                        Line(speaker: "B", start: 7, end: 9, text: "Good.")],
                                speakers: [SpeakerInfo(id: "A", seconds: 40, embedding: nil, suggestion: nil, quotes: []),
                                           SpeakerInfo(id: "B", seconds: 30, embedding: nil, suggestion: known, quotes: [])],
                                echoLinesRemoved: 0, me: nil, warnings: [], embeddingModel: voiceprintModel)
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        #expect(hasUnnamedVoices(dir))
        let server = try await StandIn.model { _ in #"{"speakers":[{"speaker":"A","name":"Joe Bloggs","quote":"Joe Bloggs, where are we"},{"speaker":"B","name":"Joe Bloggs","quote":null}]}"# }
        await suggestNames(dir, config: server.config)
        let named = try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json"))
        #expect(named.speakers.map(\.suggestion?.name) == ["Joe Bloggs", "Jane Doe"] && named.warnings.isEmpty && !hasUnnamedVoices(dir))
        let asked = try #require(server.requests.first)
        #expect(asked.messages.user.contains("John Doe (recorder): Joe Bloggs, where are we with pricing?\nSpeaker A: Nearly there.\nJane Doe: Good."))
        #expect(asked.messages.user.contains("Unidentified speakers: Speaker A\n") && asked.json["response_format"] != nil)
        #expect(asked.json["temperature"] as? Double == 0.6)

        // The model is shown "Jane Doe:" before the recognised voice's lines. That's a label, not something
        // said: it doesn't make Jane Doe a name the other voice can be given.
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let echoes = try await StandIn.model { _ in #"{"speakers":[{"speaker":"A","name":"Jane Doe","quote":null}]}"# }
        await suggestNames(dir, config: echoes.config)
        #expect(try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json")).speakers.map(\.suggestion?.name) == [nil, "Jane Doe"])

        // A model that can't be reached is noted for the review screen, and the analysis is left as it was.
        try encodeJSON(analysis).write(to: dir.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)
        let broken = try await StandIn { _ in StandIn.Response(status: 500, body: Data("no".utf8)) }
        await suggestNames(dir, config: broken.config)
        let skipped = try readJSON(Analysis.self, dir.appendingPathComponent("analysis.json"))
        #expect(skipped.speakers[0].suggestion == nil && skipped.warnings.isEmpty && skipped.nameSuggestionError?.isEmpty == false)
    }

    /// The steps the processing screen counts, and what it calls each. Getting the speech models
    /// ready comes before the first of them and counts as step 1.
    @Test func stages() {
        #expect(AnalysisStage.steps.map(\.number) == [1, 2, 3, 4, 5])
        #expect(AnalysisStage.steps.map(\.title) == ["Transcribing your microphone", "Transcribing the call audio", "Telling voices apart",
                                                     "Matching voices", "Suggesting names from the conversation"])
        #expect(AnalysisStage.allCases.filter { !$0.isStep } == [.downloadingModels, .loadingModels])
        #expect(AnalysisStage.downloadingModels.number == 1 && AnalysisStage.loadingModels.number == 1)
        #expect(AnalysisStage.downloadingModels.title == "Downloading speech models (about 500 MB, first run only)")
        #expect(LiveStage.listening.title == "Listening" && LiveStage.loadingModels.title == "Loading the speech models")
    }

    /// What stopped an analysis is said by kind, so the screen doesn't have to guess from the message.
    @Test func failuresByKind() async throws {
        // No call.json or meta.json: the recording's own details can't be read.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            try await analyse(empty, config: Config.defaults(), voiceprints: empty.appendingPathComponent("voiceprints.json")) { _ in }
            Issue.record("An analysis with nothing to read should fail")
        } catch {
            #expect(analysisFailure(error) == .unreadableRecording && !error.localizedDescription.isEmpty)
        }
        #expect(analysisFailure(CocoaError(.fileReadNoSuchFile)) == .missingAudio)
        #expect(analysisFailure(OatcakeError("anything else")) == .other)
    }

    /// An analysis.json written by 0.4.1 has no nameSuggestionError; it said the same as a warning.
    /// (The JSON is in the shape 0.4.1's encoder wrote, made up here.)
    @Test func olderAnalysisFiles() throws {
        let older = #"""
            {"echoLinesRemoved":0,"embeddingModel":"wespeaker-v2","endedAt":"2026-11-05T15:00:00.000Z","lines":[],
             "speakers":[],"startedAt":"2026-11-05T14:00:00.000Z","title":"Weekly sync",
             "warnings":["Name suggestions skipped: The model couldn’t be reached.","Something else"]}
            """#
        let read = try JSONDecoder().decode(Analysis.self, from: Data(older.utf8))
        #expect(read.nameSuggestionError == "The model couldn’t be reached." && read.warnings == ["Something else"])
        // Written again, it reads back the same.
        let again = try JSONDecoder().decode(Analysis.self, from: Data(try encodeJSON(read).utf8))
        #expect(again.nameSuggestionError == read.nameSuggestionError && again.warnings == read.warnings && again.title == "Weekly sync")
    }

    /// What the helpers print for the app, a line at a time: each survives the trip, and a line that
    /// says only some of it reads with the rest left out.
    @Test func linesFromTheHelpers() throws {
        func line(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        let step = try JSONDecoder().decode(AnalysisProgress.self, from: Data(try line(AnalysisProgress(stage: .transcribingCall, fraction: 0.5)).utf8))
        #expect(step == AnalysisProgress(stage: .transcribingCall, fraction: 0.5))
        let failed = try JSONDecoder().decode(AnalysisProgress.self, from: Data(try line(AnalysisProgress(error: "No models", failure: .speechModels)).utf8))
        #expect(failed.failure == .speechModels && failed.error == "No models")
        #expect(!(try line(AnalysisProgress(done: true))).contains("\n"))
        #expect(try JSONDecoder().decode(AnalysisProgress.self, from: Data(#"{"done":true}"#.utf8)) == AnalysisProgress(done: true))
        #expect(try JSONDecoder().decode(AnalysisProgress.self, from: Data(#"{"error":"No such file"}"#.utf8)).error == "No such file")
        #expect((try? JSONDecoder().decode(AnalysisProgress.self, from: Data("Loading model…".utf8))) == nil)

        let said = LiveTranscriptLine(track: .system, start: 12.5, end: 14, text: "Shall we start?")
        let event = try JSONDecoder().decode(LiveEvent.self, from: Data(try line(LiveEvent(line: said)).utf8))
        #expect(event.line == said && event.stage == nil && event.error == nil)
        #expect(try JSONDecoder().decode(LiveEvent.self, from: Data(try line(LiveEvent(stage: .listening)).utf8)) == LiveEvent(stage: .listening))
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

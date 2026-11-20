import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct VoiceprintTests {
    @Test func renamesAndMerges() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprints-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sample = { (call: String, at: String) in Voiceprints.Sample(embedding: [1, 0], call: call, at: at) }
        try Voiceprints(model: voiceprintModel, people: [
            "John": .init(samples: [sample("a", "2026-11-01T10:00:00.000Z"), sample("b", "2026-11-03T10:00:00.000Z")]),
            "John Smith": .init(samples: [sample("c", "2026-11-02T10:00:00.000Z")]),
            "Jane": .init(samples: [sample("d", "2026-11-04T10:00:00.000Z")]),
        ]).save(file)

        try renameVoice("John", to: "  John Smith ", file: file)
        let voices = knownVoices(file)
        #expect(voices.map(\.name) == ["Jane", "John Smith"])
        #expect(Voiceprints.load(file).people["John Smith"]?.samples.map(\.call) == ["a", "c", "b"])
        #expect(voices.last?.calls == 3)
        #expect(throws: OatcakeError.self) { try renameVoice("Nobody", to: "X", file: file) }
        #expect(throws: OatcakeError.self) { try renameVoice("Jane", to: " ", file: file) }

        try forgetVoice("Jane", file: file)
        #expect(knownVoices(file).map(\.name) == ["John Smith"])

        // A file that can't be read loads as nobody; it's kept beside the new one rather than lost to it.
        let kept = file.deletingPathExtension().appendingPathExtension("unreadable.json")
        defer { try? FileManager.default.removeItem(at: kept) }
        try "{ not what it should be".write(to: file, atomically: true, encoding: .utf8)
        try addVoiceprints([(name: "Jane", embedding: [0, 1])], call: "e", file: file)
        #expect(knownVoices(file).map(\.name) == ["Jane"] && readText(kept) == "{ not what it should be")
    }

    /// A voice is recognised only when it's clearly one person: close enough, and clear of the next closest.
    @Test func matchesOnlyWhenSure() {
        // Made-up fingerprints of length one: the score is the cosine between them.
        let unit = { (degrees: Double) -> [Float] in [Float(cos(degrees * .pi / 180)), Float(sin(degrees * .pi / 180))] }
        let sample = { (v: [Float]) in Voiceprints.Sample(embedding: v, call: "c", at: "2026-11-01T10:00:00.000Z") }
        let prints = Voiceprints(model: voiceprintModel, people: ["Jane": .init(samples: [sample(unit(0)), sample(unit(90))]), "John": .init(samples: [sample(unit(180))])])
        // Each person's best sample counts.
        #expect(prints.match(unit(10))?.name == "Jane")
        #expect(prints.match(unit(80))?.name == "Jane")
        #expect(prints.match(unit(170))?.name == "John")
        // Below 0.6 (cosine of 60 degrees is 0.5): nobody.
        #expect(prints.match(unit(-60)) == nil)
        // Two people within 0.1 of each other: nobody, rather than a guess.
        let close = Voiceprints(model: voiceprintModel, people: ["Jane": .init(samples: [sample(unit(0))]), "John": .init(samples: [sample(unit(20))])])
        #expect(close.match(unit(10)) == nil)
        #expect(close.match(unit(-30))?.name == "Jane")
        #expect(Voiceprints(model: voiceprintModel, people: [:]).match(unit(0)) == nil)
    }

    /// Ten fingerprints a person at most (the newest), and one for each call.
    @Test func keepsTheNewestTenAndOneACall() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprints-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        for call in 1...12 { try addVoiceprints([(name: "Jane", embedding: [Float(call), 0])], call: "call-\(call)", file: file) }
        #expect(Voiceprints.load(file).people["Jane"]?.samples.map(\.call) == (3...12).map { "call-\($0)" })
        // Saving the same call again replaces its fingerprint rather than adding another.
        try addVoiceprints([(name: "Jane", embedding: [99, 0])], call: "call-7", file: file)
        let samples = try #require(Voiceprints.load(file).people["Jane"]?.samples)
        #expect(samples.count == 10 && samples.last?.call == "call-7" && samples.last?.embedding == [99, 0])
        #expect(knownPeople(file) == ["Jane"])
        // Nothing to add leaves the file as it is.
        let before = readText(file)
        try addVoiceprints([], call: "call-13", file: file)
        #expect(readText(file) == before)
    }
}

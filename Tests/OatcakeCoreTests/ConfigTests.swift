import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ConfigTests {
    @Test func jargon() {
        var config = Config.defaults()
        #expect(config.jargonLine.isEmpty)
        config.jargon = ["Automattic", " ", "WooCommerce"]
        #expect(config.jargonLine.hasSuffix("Automattic, WooCommerce."))
    }

    /// Settings from when the choice was a provider: a model server of your own carries over, and
    /// anything that sent transcripts elsewhere becomes the model Oatcake runs itself.
    @Test func olderModelSettings() throws {
        func read(_ json: String) throws -> LlmConfig { try JSONDecoder().decode(LlmConfig.self, from: Data(json.utf8)) }
        let own = LocalModels.recommended().id
        #expect(try read(#"{"provider":"claude-code","claudeCode":{"model":"opus","effort":"high"}}"#) == LlmConfig(model: own))
        #expect(try read(#"{"provider":"anthropic","anthropic":{"model":"claude-opus-4-5"}}"#) == LlmConfig(model: own))
        #expect(try read(#"{"provider":"openai-compatible","openai":{"baseUrl":"https://api.openai.com/v1","model":"gpt"}}"#).model == own)
        for json in [#"{"provider":"local","local":{"baseUrl":"http://localhost:11434/v1","model":"llama3.1","effort":"low"}}"#,
                     #"{"provider":"openai-compatible","openai":{"baseUrl":"http://localhost:11434/v1","model":"llama3.1"}}"#] {
            let llm = try read(json)
            #expect(llm.model == LlmConfig.ownServer && llm.own.baseUrl == "http://localhost:11434/v1" && llm.own.model == "llama3.1")
            // Saved again, it's in today's shape, which reads back the same.
            let saved = try JSONEncoder().encode(llm)
            #expect(!String(decoding: saved, as: UTF8.self).contains("provider"))
            #expect(try JSONDecoder().decode(LlmConfig.self, from: saved) == llm)
        }
        // Today's shape: one of Oatcake's models by name. A name it doesn't know is the recommended one.
        #expect(try read(#"{"model":"qwen3-4b"}"#).model == "qwen3-4b")
        #expect(try read(#"{"model":"gpt-9"}"#).model == own)
        // Reasoning starts where each task did best, and a switch that's been set is kept.
        let start = try read(#"{"model":"qwen3-8b"}"#).reasoning
        #expect(start.summary && !start.todos && start.names && start.ask)
        let set = try read(#"{"model":"qwen3-8b","reasoning":{"todos":true,"ask":false}}"#)
        #expect(set.reasoning.summary && set.reasoning.todos && set.reasoning.names && !set.reasoning.ask)
        #expect(try JSONDecoder().decode(LlmConfig.self, from: JSONEncoder().encode(set)) == set)
        // The summary's instructions are Oatcake's own until you write yours.
        var config = Config.defaults()
        #expect(config.summaryTask == defaultSummaryInstructions)
        config.summaryInstructions = "  Three bullet points, in French.\n"
        #expect(config.summaryTask == "Three bullet points, in French.")
        #expect(try JSONDecoder().decode(Config.self, from: Data(encodeJSON(config).utf8)).summaryInstructions == config.summaryInstructions)
        // The same for what counts as a to-do. The shape they come back in isn't yours to change.
        #expect(config.todosTask == defaultTodoInstructions + "\n" + todosFormat)
        config.todoInstructions = "  Only my own action items.\n"
        #expect(config.todosTask == "Only my own action items.\n" + todosFormat)
        #expect(try JSONDecoder().decode(Config.self, from: Data(encodeJSON(config).utf8)).todoInstructions == config.todoInstructions)
        #expect(try JSONDecoder().decode(Config.self, from: Data(#"{"myName":"Sam"}"#.utf8)).todoInstructions == "")
    }

    @Test func olderConfig() throws {
        let old = #"{"myName":"Sam","outputDir":"/tmp/m","asrModel":"parakeet-unified-en","keepAudio":false,"mic":null,"callReminders":false,"updateCheck":true}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.callNotice && config.autoStop && config.liveTranscript && config.menuBarNextCall && config.jargon.isEmpty)
        #expect(!config.callReminders && config.myName == "Sam")
        let again = try JSONDecoder().decode(Config.self, from: Data(encodeJSON(with(config) { $0.autoStop = false; $0.jargon = ["Jetpack"] }).utf8))
        #expect(!again.autoStop && again.jargon == ["Jetpack"])
    }

    /// Settings that can't be read aren't quietly replaced by the first change made after them.
    @Test func settingsThatCannotBeRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json"), kept = dir.appendingPathComponent("config.unreadable.json")
        // None yet: the ones Oatcake comes with are written, and there's nothing to say.
        #expect(Config.loadWithProblem(file: file).problem == nil && FileManager.default.fileExists(atPath: file.path))
        try with(Config.defaults()) { $0.myName = "Sam"; $0.outputDir = "/tmp/m" }.save(to: file)
        let read = Config.loadWithProblem(file: file)
        #expect(read.config.myName == "Sam" && read.problem == nil && !FileManager.default.fileExists(atPath: kept.path))
        // A hand edit that went wrong.
        try #"{"myName": "Sam", "outputDir": }"#.write(to: file, atomically: true, encoding: .utf8)
        let broken = Config.loadWithProblem(file: file)
        #expect(broken.config.outputDir == Config.defaults().outputDir && broken.problem?.contains("config.unreadable.json") == true)
        #expect(readText(kept) == #"{"myName": "Sam", "outputDir": }"#)
    }
}

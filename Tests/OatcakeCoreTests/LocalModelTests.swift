import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct LocalModelTests {
    @Test func localModelsOnly() async throws {
        // This Mac, a machine on your network, or a private address.
        for address in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1", "http://mac-studio:11434/v1", "http://ollama/v1",
                        "http://studio.local:11434/v1", "http://192.168.1.20:11434/v1", "http://10.0.0.5/v1", "https://172.20.1.1/v1"] {
            #expect(isLocalEndpoint(address), "\(address)")
        }
        // Anyone else's service, or not an address at all.
        for address in ["https://api.openai.com/v1", "https://openrouter.ai/api/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1",
                        "https://localhost.example.com/v1", "ftp://localhost/v1", "localhost:11434", "",
                        // A public address written as one number isn't a machine's name.
                        "http://134744072/v1", "http://0x08080808/v1",
                        // Nor one with a leading zero, which is read two ways.
                        "http://010.8.8.8/v1", "http://0177.0.0.1/v1"] {
            #expect(!isLocalEndpoint(address), "\(address)")
        }
        // A server of your own pointed somewhere else is refused before anything is sent.
        var config = LlmConfig(model: LlmConfig.ownServer)
        config.own.baseUrl = "https://api.openai.com/v1"
        config.own.model = "gpt"
        await #expect(throws: OatcakeError(notLocalMessage)) {
            _ = try await withModel(config, tokens: 100) { chat, _ in try await chat.complete([ChatMessage("user", "Hello")]) }
        }
        // No key is kept for a model any more.
        #expect(SecretName.allCases.map(\.rawValue) == ["calendar"])
    }

    /// Which model a Mac starts with, and how much it's given to read at once, go by its memory.
    @Test func modelsByMemory() {
        let big = LocalModels.all[0], small = LocalModels.all[1]
        #expect(LocalModels.recommended(memory: 8) == small && LocalModels.recommended(memory: 16) == big && LocalModels.recommended(memory: 36) == big)
        #expect(!LocalModels.fits(big, memory: 8) && LocalModels.fits(small, memory: 8) && LocalModels.fits(big, memory: 16))
        #expect(LocalModels.maxContext(small, memory: 8) == 16_384)
        #expect(LocalModels.maxContext(big, memory: 16) == 32_768)
        #expect(LocalModels.maxContext(big, memory: 36) == 131_072)
        // The smallest window that holds the job, so no more memory is taken than it needs.
        #expect(LocalModels.context(forTokens: 3_000) == 8_192 && LocalModels.context(forTokens: 20_000) == 24_576)
        #expect(LocalModels.context(forTokens: 500_000) == 131_072)
        // A window stretched past the model's own is for a text that needs it: a job that fits never
        // borrows a server that's running stretched, and a bigger window of the same kind is shared.
        #expect(LocalModels.stretch(32_768) == 1 && LocalModels.stretch(49_152) == 2 && LocalModels.stretch(131_072) == 4)
        #expect(LocalModels.serves(running: 32_768, needed: 8_192) && LocalModels.serves(running: 65_536, needed: 49_152))
        #expect(!LocalModels.serves(running: 49_152, needed: 32_768) && !LocalModels.serves(running: 16_384, needed: 32_768))
        // The files are the ones that were measured: a fixed revision, with its size and checksum.
        for model in LocalModels.all {
            #expect(model.url.hasPrefix("https://huggingface.co/Qwen/") && model.url.contains("/resolve/") && model.url.hasSuffix(model.file))
            #expect(model.sha256.count == 64 && model.bytes > 2_000_000_000)
        }
    }

    /// What goes to the model's server: Qwen's own sampling for each mode, its reasoning switch, the
    /// shape a reply must fit, and the key Oatcake made up for its own server.
    @Test func requests() async throws {
        let server = try await StandIn.model { _ in "<think>\nLet me see.\n</think>\n\nOK" }
        let own = LocalChat(baseUrl: server.address + "/v1", model: "qwen3-8b", key: "made-up", qwen: true)
        #expect(await own.isReady() && server.requests.last?.path == "/health")
        #expect(try await own.complete([ChatMessage("system", "Be brief."), ChatMessage("user", "Say OK.")], schema: todosSchema) == "OK")
        #expect(try await own.complete([ChatMessage("user", "Say OK.")], think: false, maxTokens: 20) == "OK")
        let sent = server.requests.filter { $0.path == "/v1/chat/completions" }
        #expect(sent.count == 2 && sent.allSatisfy { $0.headers["authorization"] == "Bearer made-up" })
        let thinking = sent[0].json, plain = sent[1].json
        #expect(thinking["temperature"] as? Double == 0.6 && thinking["top_p"] as? Double == 0.95 && thinking["top_k"] as? Int == 20)
        #expect(thinking["presence_penalty"] as? Double == 1.5 && thinking["min_p"] as? Int == 0 && thinking["cache_prompt"] as? Bool == true)
        #expect((thinking["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true)
        #expect(((thinking["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] != nil)
        // The schema arrives as it's written, its fields in their order: the model fills them in that order.
        #expect(String(decoding: sent[0].body, as: UTF8.self).contains("\"schema\":" + todosSchema))
        #expect(thinking["max_tokens"] as? Int == 8_192 && sent[0].messages.system == "Be brief.")
        #expect(plain["temperature"] as? Double == 0.7 && plain["top_p"] as? Double == 0.8 && plain["max_tokens"] as? Int == 20)
        #expect((plain["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false && plain["response_format"] == nil)

        // A server of your own gets no key and no switch it may not know.
        let yours = try await withModel(server.config.llm, tokens: 100) { chat, context in
            #expect(context == LocalModels.nativeContext)
            return try await chat.complete([ChatMessage("user", "Say OK.")])
        }
        #expect(yours == "OK" && server.requests.last?.headers["authorization"] == nil && server.requests.last?.json["chat_template_kwargs"] == nil)

        // A reply that's all reasoning, cut off before the answer, is an error rather than an empty summary.
        let cut = try await StandIn { _ in
            StandIn.Response(body: Data(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#.utf8))
        }
        await #expect(throws: OatcakeError(outOfRoomMessage)) {
            _ = try await LocalChat(baseUrl: cut.address + "/v1", model: "m").complete([ChatMessage("user", "Hello")])
        }
    }

    /// A server of your own is told whether to reason only in the way you've said it takes: Ollama's
    /// reasoning_effort, or llama.cpp's enable_thinking. Left to the server, neither is sent.
    @Test func ownServerReasoningControl() async throws {
        let server = try await StandIn.model { _ in "OK" }
        func sent(_ control: LlmConfig.ReasoningControl?, think: Bool) async throws -> [String: Any] {
            var own = server.config.llm.own
            own.reasoningControl = control
            _ = try await LocalChat(own: own).complete([ChatMessage("user", "Say OK.")], think: think)
            return try #require(server.requests.last).json
        }
        let ollamaOn = try await sent(.ollama, think: true), ollamaOff = try await sent(.ollama, think: false)
        #expect(ollamaOn["reasoning_effort"] as? String == "medium" && ollamaOff["reasoning_effort"] as? String == "none")
        #expect(ollamaOn["chat_template_kwargs"] == nil && ollamaOff["chat_template_kwargs"] == nil)
        let llamaOn = try await sent(.llamaCpp, think: true), llamaOff = try await sent(.llamaCpp, think: false)
        #expect((llamaOn["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == true && llamaOn["reasoning_effort"] == nil)
        #expect((llamaOff["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        for think in [true, false] {
            let left = try await sent(nil, think: think)
            #expect(left["reasoning_effort"] == nil && left["chat_template_kwargs"] == nil)
        }
        // Oatcake's own Qwen is told as before, and never in Ollama's way.
        _ = try await LocalChat(baseUrl: server.address + "/v1", model: "qwen3-8b", key: "made-up", qwen: true).complete([ChatMessage("user", "Say OK.")], think: false)
        let qwen = try #require(server.requests.last).json
        #expect((qwen["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false && qwen["reasoning_effort"] == nil)

        // Settings: read on its own, and a value Oatcake doesn't know leaves it to the server.
        var llm = server.config.llm
        llm.own.reasoningControl = .llamaCpp
        #expect(try JSONDecoder().decode(LlmConfig.self, from: JSONEncoder().encode(llm)).own.reasoningControl == .llamaCpp)
        let unknown = try JSONDecoder().decode(LlmConfig.self, from: Data(#"{"model":"own","own":{"baseUrl":"http://localhost:11434/v1","model":"gemma4","reasoningControl":"lmstudio"}}"#.utf8))
        #expect(unknown.own.reasoningControl == nil && unknown.own.model == "gemma4")
    }

    /// Ollama answers a request to reason, sent to a model that can't, with a 400 (its words, from
    /// server/routes.go). Oatcake asks once more without reasoning_effort instead of failing the task.
    @Test func ollamaModelThatCantReason() async throws {
        let server = try await StandIn { request in
            request.json["reasoning_effort"] as? String == "medium"
                ? StandIn.Response(status: 400, body: Data(#"{"error":"\"llama3.2\" does not support thinking"}"#.utf8))
                : .chat("OK")
        }
        var own = server.config.llm.own
        own.reasoningControl = .ollama
        #expect(try await LocalChat(own: own).complete([ChatMessage("user", "Say OK.")], think: true) == "OK")
        #expect(server.requests.count == 2 && server.requests[1].json["reasoning_effort"] == nil)
        // Turning reasoning off ("none") is never refused, so it's sent once as it is.
        #expect(try await LocalChat(own: own).complete([ChatMessage("user", "Say OK.")], think: false) == "OK")
        #expect(server.requests.count == 3 && server.requests[2].json["reasoning_effort"] as? String == "none")
        // Any other refusal is still an error.
        let other = try await StandIn { _ in StandIn.Response(status: 400, body: Data(#"{"error":"model not found"}"#.utf8)) }
        var missing = other.config.llm.own
        missing.reasoningControl = .ollama
        await #expect(throws: OatcakeError.self) {
            try await LocalChat(own: missing).complete([ChatMessage("user", "Say OK.")], think: true)
        }
        #expect(other.requests.count == 1)
    }

    /// A model's file is carried on from where an earlier download stopped, and only kept when it's
    /// the file that was expected.
    @Test func downloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
        let server = try await StandIn { request in
            guard let range = request.headers["range"], let from = Int(range.replacingOccurrences(of: "bytes=", with: "").dropLast()) else {
                return StandIn.Response(body: content)
            }
            return StandIn.Response(status: 206, headers: ["Content-Range": "bytes \(from)-\(content.count - 1)/\(content.count)"], body: content[from...])
        }
        func model(sha256: String) -> LocalModel {
            LocalModel(id: "test", title: "Test model", detail: "", file: "test.gguf", url: server.address + "/test.gguf", sha256: sha256,
                       bytes: Int64(content.count), baseMemory: 1, memoryPerThousandTokens: 0.1)
        }
        let good = model(sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
        let file = dir.appendingPathComponent("test.gguf"), part = file.appendingPathExtension("part")

        // The first third is here already: only the rest is asked for.
        try content[..<100_000].write(to: part)
        // Without room for the rest and a gigabyte to spare, it says so and asks for nothing.
        do {
            try await ModelDownload.fetch(good, to: file, available: 150_000) { _ in }
            Issue.record("downloaded without room")
        } catch {
            #expect(error.localizedDescription.contains("isn’t room") && server.requests.isEmpty)
        }
        try await ModelDownload.fetch(good, to: file) { _ in }
        #expect(try Data(contentsOf: file) == content && !FileManager.default.fileExists(atPath: part.path))
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == "bytes=100000-")
        // It's here now: nothing is fetched.
        try await ModelDownload.fetch(good, to: file) { _ in }
        #expect(server.requests.count == 1)

        // From nothing, and a file that isn't the one expected is thrown away.
        try FileManager.default.removeItem(at: file)
        await #expect(throws: OatcakeError.self) { try await ModelDownload.fetch(model(sha256: String(repeating: "0", count: 64)), to: file) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: part.path))
        #expect(server.requests.last?.headers["range"] == nil)
    }
}

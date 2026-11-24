// Talking to the language model. It's always a model on this Mac (see LocalModel.swift) or on a
// server of your own on your network; both speak the same chat API. It only ever sees text.

import Foundation

/// What a local model's address gets when it isn't local (settings from a version that allowed any address).
public let notLocalMessage = "A model server of your own has to be on this Mac or your own network, and this address isn’t. Change it in Settings › Models, or choose one of Oatcake’s own models there."

/**
 * Whether a model server's address is on this Mac or your own network: localhost, a name with no
 * dots or ending in .local, or a private or link-local IP address. Oatcake sends transcripts to a
 * local model only at an address like that, so one can't be pointed at somebody else's service.
 */
public func isLocalEndpoint(_ address: String) -> Bool {
    guard let url = URL(string: address.trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return false }
    if host.contains(":") {
        // IPv6: this Mac, link-local, or a unique local address.
        return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
            || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    // A part with a leading zero (010.8.8.8) is read as ten by some of the system and as eight by the
    // rest: whichever a request would use, it isn't how anyone writes an address they mean.
    if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), parts.contains(where: { $0.count > 1 && $0.first == "0" }) { return false }
    if parts.count == 4, let n = Optional(parts.compactMap { UInt8($0) }), n.count == 4 {
        return n[0] == 127 || n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168) || (n[0] == 169 && n[1] == 254)
    }
    // A bare number is an address written another way (134744072 is 8.8.8.8), not a machine's name.
    if UInt64(host) != nil || host.hasPrefix("0x") { return false }
    // A name: this Mac, a machine named on your network, or a Bonjour name.
    return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".")
}

/// One turn of a conversation with the model.
public struct ChatMessage: Sendable, Equatable {
    public var role: String
    public var content: String
    public init(_ role: String, _ content: String) {
        self.role = role
        self.content = content
    }
}

/**
 * A chat server at a local address. Requests follow Qwen's own advice for its models: its sampling
 * settings for each mode, never greedy decoding, room for a long reply, and nothing of its
 * reasoning kept in the conversation. Whether it reasons before it replies is the caller's to say:
 * Settings › Summaries has a switch for each task (LlmConfig.Reasoning).
 */
public struct LocalChat: Sendable {
    public var baseUrl: String
    public var model: String
    /// The key Oatcake made up for its own server. None is sent to a server of yours.
    var key: String?
    /// Oatcake's own server runs Qwen3, which takes its reasoning switch from the chat template.
    var qwen = false
    /// A server of your own's reasoning switch, if you've said which it takes (Settings › Models).
    var reasoningControl: LlmConfig.ReasoningControl?

    public init(baseUrl: String, model: String) {
        self.baseUrl = baseUrl
        self.model = model
    }

    /// A server of your own, as Settings › Models has it.
    init(own: LlmConfig.Own) {
        self.init(baseUrl: own.baseUrl, model: own.model)
        reasoningControl = own.reasoningControl
    }

    init(baseUrl: String, model: String, key: String?, qwen: Bool) {
        self.baseUrl = baseUrl
        self.model = model
        self.key = key
        self.qwen = qwen
    }

    private func request(_ path: String, timeout: TimeInterval) throws -> URLRequest {
        guard !baseUrl.trimmed.isEmpty, !model.trimmed.isEmpty else { throw OatcakeError("Set the endpoint and model in Settings first.") }
        guard isLocalEndpoint(baseUrl) else { throw OatcakeError(notLocalMessage) }
        guard let url = URL(string: baseUrl.trimmed.replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression) + path) else {
            throw OatcakeError("The endpoint isn’t a valid address.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        return request
    }

    /// Whether Oatcake's own server has finished loading its model: llama.cpp's /health says so.
    func isReady() async -> Bool {
        let root = baseUrl.trimmed.replacingOccurrences(of: #"/v1/?$"#, with: "", options: .regularExpression)
        guard let url = URL(string: root + "/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /**
     * The model's reply to a conversation. `schema` is a JSON Schema the reply must fit (the server
     * holds the model to it). `maxTokens` is room for the reasoning and the reply together.
     */
    public func complete(_ messages: [ChatMessage], schema: String? = nil, think: Bool = true, maxTokens: Int = 8_192) async throws -> String {
        var request = try request("/chat/completions", timeout: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            // Qwen3's recommended sampling: thinking and non-thinking modes each have their own.
            "temperature": think ? 0.6 : 0.7,
            "top_p": think ? 0.95 : 0.8,
            "top_k": 20,
            "min_p": 0,
            "presence_penalty": 1.5,
            // The server keeps its reading of a prompt, so a second question about the same call starts at once.
            "cache_prompt": true,
        ]
        if qwen { body["chat_template_kwargs"] = ["enable_thinking": think] }
        // A server of your own is told only in the way you've said it understands. "medium" is a level
        // Ollama knows for every model that reasons; a model that only has on and off takes it as on.
        switch reasoningControl {
        case .ollama: body["reasoning_effort"] = think ? "medium" : "none"
        case .llamaCpp: body["chat_template_kwargs"] = ["enable_thinking": think]
        case nil: break
        }
        // The schema is sent exactly as it's written. The server makes the model fill in a reply's
        // fields in the schema's order, and that order matters: asked for a to-do's time before
        // its task, the model walks the call minute by minute and makes a to-do of each. Passed
        // through a dictionary, the fields came out in another order (the time first).
        let placeholder = "schema-\(UUID().uuidString)"
        let schemaAsWritten = schema.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil ? $0 : nil }
        if schemaAsWritten != nil {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "strict": true, "schema": placeholder]]
        }
        var sent = try JSONSerialization.data(withJSONObject: body)
        if let schemaAsWritten {
            sent = Data(String(decoding: sent, as: UTF8.self).replacingOccurrences(of: "\"\(placeholder)\"", with: schemaAsWritten).utf8)
        }
        request.httpBody = sent
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let said = String(decoding: data, as: UTF8.self)
            // Ollama refuses to turn reasoning on for a model that can't reason ("… does not support
            // thinking", a 400 on its chat API). Asked again without the switch, that model just replies.
            if reasoningControl == .ollama, think, status == 400, said.contains("does not support thinking") {
                var plain = self
                plain.reasoningControl = nil
                return try await plain.complete(messages, schema: schema, think: think, maxTokens: maxTokens)
            }
            throw OatcakeError("The model at \(baseUrl) returned \(status): \(said.prefix(300))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (json?["choices"] as? [[String: Any]])?.first
        let reply = withoutReasoning(((choice?["message"] as? [String: Any])?["content"] as? String) ?? "")
        guard !reply.isEmpty else {
            // Its reasoning used up the room before it got to the reply.
            throw OatcakeError(choice?["finish_reason"] as? String == "length" ? outOfRoomMessage : "The model gave an empty reply.")
        }
        return reply
    }
}

/// What a small model writes where it was asked to leave a value empty.
let wordsForNothing: Set<String> = ["null", "none", "n/a", "unknown", "not stated", "not specified", "tbd"]

let outOfRoomMessage = "The model ran out of room before it finished its reply. Trying again usually works."

/// A reply without the model's reasoning, for servers that leave it in the text between <think> tags.
func withoutReasoning(_ reply: String) -> String {
    reply.replacingOccurrences(of: #"(?s)^\s*<think>.*?</think>"#, with: "", options: .regularExpression).trimmed
}

/**
 * Runs `work` with the model that's set in Settings, with room for a prompt of `tokens` tokens and
 * its reply. For one of Oatcake's own models this starts its server if it isn't running, with the
 * smallest window that fits (never more than this Mac has memory for), and keeps it as it is until
 * `work` is done. `work` is also told how many tokens the window holds. `server` is Oatcake's one
 * server, except in tests.
 */
public func withModel<T: Sendable>(_ config: LlmConfig, tokens: Int, server: ModelServer = .shared,
                                    _ work: (LocalChat, Int) async throws -> T) async throws -> T {
    guard let model = LocalModels.find(config.model) else {
        // A server of your own decides its window; Qwen's native one is assumed.
        return try await work(LocalChat(own: config.own), LocalModels.nativeContext)
    }
    let context = min(LocalModels.context(forTokens: tokens), LocalModels.maxContext(model))
    let chat = try await server.lease(model, context: context)
    do {
        let result = try await work(chat, context)
        await server.release()
        return result
    } catch {
        await server.release()
        throw error
    }
}

/// The most tokens the chosen model can be given at once on this Mac.
public func largestContext(_ config: LlmConfig) -> Int {
    LocalModels.find(config.model).map { LocalModels.maxContext($0) } ?? LocalModels.nativeContext
}

/**
 * A model failure in plain words, with what to do about it. The raw message is shown behind
 * "Details" by the windows; an error that's already plain comes back unchanged.
 */
public func explainModelError(_ raw: String) -> String {
    if raw == notLocalMessage || raw == modelNotDownloadedMessage || raw == outOfRoomMessage { return raw }
    let e = raw.lowercased()
    if e.contains("context") && (e.contains("exceed") || e.contains("too long") || e.contains("too large")) {
        return "This call is too long for the model to take in at once on this Mac."
    }
    if e.contains("model") && (e.contains("not found") || e.contains("does not exist") || e.contains("not exist")) {
        let model = firstMatch(try! NSRegularExpression(pattern: #""model"\s*:\s*"([^"]+)""#), raw)?[1]
        return "The model\(model.map { " “\($0)”" } ?? "") isn’t on that server. Check its name in Settings › Models."
    }
    if e.contains("could not connect") || e.contains("couldn’t connect") || e.contains("offline") || e.contains("timed out") || e.contains("hostname") || e.contains("connection") {
        return "The model couldn’t be reached. If it’s a server of your own, check that it’s running."
    }
    return raw
}

/// Pulls the first JSON object out of a model reply (tolerates code fences and prose).
public func parseJsonObject<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
        throw OatcakeError("No JSON in model reply: \(text.prefix(200))")
    }
    return try JSONDecoder().decode(T.self, from: Data(text[start...end].utf8))
}

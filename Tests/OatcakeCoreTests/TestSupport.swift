// What the tests share: the fixtures, a stand-in for the model's server, and a Meetings folder to work in.

import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

/// A small HTTP server on this Mac's own address, standing in for the language model's server (and
/// for the site a model is downloaded from). It answers each request with what `handler` returns.
final class StandIn: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var headers: [String: String]
        var body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        /// The system and user messages of a chat request.
        var messages: (system: String, user: String) {
            let all = json["messages"] as? [[String: Any]] ?? []
            func content(_ role: String) -> String { all.last { $0["role"] as? String == role }?["content"] as? String ?? "" }
            return (content("system"), content("user"))
        }
    }
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// A chat completion whose message is `content`.
        static func chat(_ content: String) -> Response {
            let json: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content], "finish_reason": "stop"]]]
            return Response(body: try! JSONSerialization.data(withJSONObject: json))
        }
    }

    private let listener: NWListener
    private let handler: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var seen: [Request] = []
    var requests: [Request] { lock.withLock { seen } }
    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var address: String { "http://127.0.0.1:\(port)" }

    init(_ handler: @escaping @Sendable (Request) -> Response) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let listener = listener
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }

    /// A model server that answers each chat request with what `reply` returns.
    static func model(_ reply: @escaping @Sendable (Request) -> String) async throws -> StandIn {
        try await StandIn { .chat(reply($0)) }
    }

    /// Settings that send every request for the model here.
    var config: Config {
        var config = Config.defaults()
        config.myName = "Sam Taylor"
        config.llm = LlmConfig(model: LlmConfig.ownServer)
        config.llm.own.baseUrl = address + "/v1"
        config.llm.own.model = "stand-in"
        return config
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        var buffer = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.lock.withLock { self.seen.append(request) }
                    let response = self.handler(request)
                    var head = "HTTP/1.1 \(response.status) OK\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                    for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
                    connection.send(content: Data((head + "\r\n").utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
                } else if done || error != nil {
                    connection.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    /// A whole request, once all of it has arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...]).trimmed
        }
        let body = data[end.upperBound...]
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }
        let first = lines.first?.split(separator: " ") ?? []
        return Request(path: first.count > 1 ? String(first[1]) : "", headers: headers, body: Data(body))
    }
}

/// A Meetings folder for a test, with a way to put meetings in it.
struct TestMeetings {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-model-\(UUID().uuidString)")

    func write(_ rel: String, _ file: MeetingFile, _ text: String, meta: String = "{}") throws {
        let dir = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.json").path) {
            try meta.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        }
        try text.write(to: dir.appendingPathComponent(file.rawValue), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}

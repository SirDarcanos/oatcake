import Foundation
import Darwin
import Network
import Security

/// A local, stateless Streamable HTTP endpoint. All listener and connection state lives on `queue`.
public final class MCPServer: @unchecked Sendable {
    public enum Status: Sendable { case running(UInt16), failed(String) }
    public static let port: UInt16 = 8765

    /// Persisted with the user's opt-in, so relaunch does not implicitly approve a replacement folder.
    public struct RootIdentity: Codable, Equatable, Sendable {
        private let device: dev_t
        private let inode: ino_t
        private let birthSeconds: Int
        private let birthNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }

        public static func approve(_ root: URL) throws -> Self {
            try MeetingMCP(root: root, approved: nil).identity
        }
    }
    private let queue = DispatchQueue(label: "Oatcake.MCP")
    private let work = DispatchQueue(label: "Oatcake.MCP.library", qos: .utility)
    private var pending = 0
    private let listener: NWListener
    private let library: MeetingMCP
    private let token: String
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiving: Set<ObjectIdentifier> = []
    private let beforeReply: @Sendable () -> Void
    private let status: @Sendable (Status) -> Void
    private var stopped = false
    private var rootInvalidated = false

    public static func savedToken() throws -> String {
        let file = Paths.data.appendingPathComponent("mcp-token")
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try String(contentsOf: file, encoding: .utf8).trimmed
            guard saved.count == 64, saved.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw OatcakeError("The MCP access token is invalid. Remove the mcp-token file from Oatcake’s data folder and try again.")
            }
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OatcakeError("Couldn’t create an MCP access token. Try turning MCP off and on again.")
        }
        let saved = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: Paths.data, withIntermediateDirectories: true)
        try writeAtomic(file, saved + "\n", permissions: 0o600)
        return saved
    }

    public static func configuration(token: String) -> String {
        let config = ["mcpServers": ["oatcake": ["url": "http://127.0.0.1:\(port)/mcp",
                                                  "headers": ["Authorization": "Bearer \(token)"]] as [String: Any]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public convenience init(root: URL, approved: RootIdentity, token: String, port: UInt16 = MCPServer.port,
                            status: @escaping @Sendable (Status) -> Void) throws {
        try self.init(root: root, approved: approved, token: token, port: port, beforeReply: {}, status: status)
    }

    init(root: URL, approved: RootIdentity, token: String, port: UInt16,
         beforeReply: @escaping @Sendable () -> Void, status: @escaping @Sendable (Status) -> Void) throws {
        library = try MeetingMCP(root: root, approved: approved)
        self.beforeReply = beforeReply
        self.status = status
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let bound = self?.listener.port { status(.running(bound.rawValue)) }
            case .failed, .waiting: status(.failed("Can’t start MCP on port \(port). If another app is using it, close that app, then turn MCP off and on again."))
            default: break
            }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            receiving.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 32 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        receiving.insert(id)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
            if let self, let connection, self.receiving.contains(id) { self.finish(connection) }
        }
        receive(connection, Data())
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        receiving.remove(id)
    }

    private func receive(_ connection: NWConnection, _ buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.stopped, self.connections[ObjectIdentifier(connection)] != nil else { return }
            guard error == nil, let data else { self.finish(connection); return }
            let received = buffered + data
            if self.handle(connection, received) { return }
            if complete { self.send(connection, "400 Bad Request") } else { self.receive(connection, received) }
        }
    }

    private func handle(_ connection: NWConnection, _ bytes: Data) -> Bool {
        func end(_ code: String, header: String = "") -> Bool { send(connection, code, header: header); return true }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count > 16384 ? end("431 Request Header Fields Too Large") : false
        }
        guard boundary.lowerBound <= 16384, let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else {
            return end("400 Bad Request")
        }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { return end("400 Bad Request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return end("400 Bad Request") }
            let key = line[..<colon].lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[key] == nil, !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else { return end("400 Bad Request") }
            headers[key] = value
        }
        guard let port = listener.port?.rawValue else { return end("503 Service Unavailable") }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = headers["host"]?.lowercased(), hosts.contains(host),
              headers["origin"].map({ hosts.map { "http://" + $0 }.contains($0) }) ?? true else { return end("403 Forbidden") }
        guard request[1] == "/mcp" else { return end("404 Not Found") }
        guard authorised(headers["authorization"]) else { return end("401 Unauthorized", header: "WWW-Authenticate: Bearer\r\n") }
        guard !rootInvalidated else { return end("503 Service Unavailable") }
        if let version = headers["mcp-protocol-version"], !MeetingMCP.versions.contains(version) { return end("400 Bad Request") }
        guard request[0] == "POST" else { return end("405 Method Not Allowed", header: "Allow: POST\r\n") }
        guard headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else { return end("415 Unsupported Media Type") }
        let framed = bytes[boundary.upperBound...]
        let body: Data
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { return end("400 Bad Request") }
            guard framed.count <= 2 * Self.bodyLimit else { return end("413 Content Too Large") }
            switch Self.decodeChunks(framed) {
            case .incomplete: return false
            case .invalid: return end("400 Bad Request")
            case .tooLarge: return end("413 Content Too Large")
            case .complete(let data): body = data
            }
        } else {
            guard let size = headers["content-length"], !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(size), length > 0 else { return end("400 Bad Request") }
            guard length <= Self.bodyLimit else { return end("413 Content Too Large") }
            guard framed.count >= length else { return false }
            guard framed.count == length else { return end("400 Bad Request") }
            body = framed
        }
        receiving.remove(ObjectIdentifier(connection))
        guard pending < 8 else { return end("503 Service Unavailable") }
        pending += 1
        work.async { [weak self] in
            guard let self else { return }
            let active = self.queue.sync { self.connections[ObjectIdentifier(connection)] != nil }
            let result = active ? self.library.respond(body) : nil
            if active { self.beforeReply() }
            self.queue.async {
                self.pending -= 1
                guard self.connections[ObjectIdentifier(connection)] != nil else { return }
                if self.rootInvalidated || !self.library.rootStillSelected() {
                    if !self.rootInvalidated {
                        self.rootInvalidated = true
                        self.status(.failed("The Meetings folder has changed. Check the folder in Storage, then turn MCP off and on again."))
                    }
                    self.send(connection, "503 Service Unavailable")
                } else if let result {
                    self.send(connection, "200 OK", header: "Content-Type: application/json\r\nCache-Control: no-store\r\n", body: result)
                } else {
                    self.send(connection, "202 Accepted")
                }
            }
        }
        return true
    }

    private static let bodyLimit = 1_048_576
    enum ChunkResult: Equatable { case incomplete, invalid, tooLarge, complete(Data) }

    static func decodeChunks(_ framed: Data) -> ChunkResult {
        let crlf = Data([13, 10])
        var i = framed.startIndex
        var body = Data()
        while true {
            guard let line = framed[i...].range(of: crlf) else {
                return framed.endIndex - i > 1024 ? .invalid : .incomplete
            }
            guard line.lowerBound - i <= 1024 else { return .invalid }
            let size = framed[i..<line.lowerBound].prefix { $0 != 59 } // Ignore chunk extensions.
            guard !size.isEmpty, size.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let count = Int(String(decoding: size, as: UTF8.self), radix: 16) else { return .invalid }
            i = line.upperBound
            if count == 0 {
                while let trailer = framed[i...].range(of: crlf) {
                    if trailer.lowerBound == i { return trailer.upperBound == framed.endIndex ? .complete(body) : .invalid }
                    guard framed[i..<trailer.lowerBound].contains(58) else { return .invalid }
                    i = trailer.upperBound
                }
                return .incomplete
            }
            guard count <= bodyLimit - body.count else { return .tooLarge }
            guard framed.endIndex - i >= count + 2 else { return .incomplete }
            guard framed[i + count] == 13, framed[i + count + 1] == 10 else { return .invalid }
            body.append(contentsOf: framed[i..<(i + count)])
            i += count + 2
        }
    }

    private func authorised(_ header: String?) -> Bool {
        guard let parts = header?.split(separator: " "), parts.count == 2, parts[0].lowercased() == "bearer",
              parts[1].utf8.count == token.utf8.count else { return false }
        return zip(parts[1].utf8, token.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func send(_ connection: NWConnection, _ status: String, header: String = "", body: Data = Data()) {
        let response = Data("HTTP/1.1 \(status)\r\n\(header)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
    }
}

import Foundation
import Darwin
import CoreFoundation

/**
 * Oatcake's MCP server: `Oatcake --mcp`, started by an app on this Mac that you've added it to, and
 * talking to that app alone over its standard input and output, one JSON-RPC message per line.
 * Nothing listens on the network, so there's no port another program could take and no token to
 * keep secret: what it can read is what the app that started it may read.
 *
 * It only reads the saved meeting documents (MeetingMCP), and only while Settings › Storage lets
 * other apps read them. The settings are read again for every tool call, so turning that off, or
 * choosing another Meetings folder, reaches a server that's already running.
 */
public final class MCPServer {
    /// Persisted with the user's opt-in, so a folder put in the Meetings folder's place isn't served.
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

    static let versions = ["2025-11-25", "2025-06-18"]
    private static let arguments = ["browse_meetings": [], "search_meetings": ["query"], "read_meeting": ["path"], "list_todos": []]
    /// The longest message read. A longer one is answered with an error and skipped.
    static let lineLimit = 1_048_576

    private let loadConfig: () -> Config?
    /// For tests: runs after a tool has read the folder and before its reply is made.
    private let beforeReply: () -> Void
    private var library: MeetingMCP?

    init(loadConfig: @escaping () -> Config?, beforeReply: @escaping () -> Void = {}) {
        self.loadConfig = loadConfig
        self.beforeReply = beforeReply
    }

    /// What to add to an app's MCP settings: Oatcake's own executable, run with --mcp.
    public static func configuration(executable: String) -> String {
        let config = ["mcpServers": ["oatcake": ["command": executable, "args": [HelperMode.mcp]] as [String: Any]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Serves the app that started it until that app closes its end. Returns the exit status.
    public static func run() -> Int32 {
        // An app that goes away mid-reply ends the server through a failed write, not a signal.
        signal(SIGPIPE, SIG_IGN)
        MCPServer(loadConfig: { savedConfig() }).serve(input: FileHandle.standardInput.fileDescriptor,
                                                       output: FileHandle.standardOutput.fileDescriptor)
        return 0
    }

    /**
     * The settings as they're saved. Not Config.load: that repairs a file it can't read and writes
     * the defaults when there's none, and a server only reads.
     */
    static func savedConfig(_ file: URL = Paths.config) -> Config? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Reads messages a line at a time and answers each that asks for an answer, until end of input.
    func serve(input: Int32, output: Int32) {
        var buffer = Data()
        // The rest of a message that was too long, up to its newline.
        var skipping = false
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let tooLarge = Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Message too large"]])
        func send(_ reply: Data) -> Bool {
            let line = reply + Data([10])
            return line.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let n = Darwin.write(output, bytes.baseAddress! + sent, bytes.count - sent)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { return false }
                    sent += n
                }
                return true
            }
        }
        while true {
            let count = read(input, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                if skipping { skipping = false; continue }
                let reply = line.count > Self.lineLimit ? tooLarge : respond(line)
                if let reply, !send(reply) { return }
            }
            if skipping {
                buffer.removeAll()
            } else if buffer.count > Self.lineLimit {
                buffer.removeAll()
                skipping = true
                if !send(tooLarge) { return }
            }
        }
        // A last message without its newline is still answered.
        if !skipping, let reply = respond(buffer) { _ = send(reply) }
    }

    /// One line of JSON. Paths keep their slashes as they are ("Projects/Launch", not "Projects\/Launch").
    private static func encode(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: .withoutEscapingSlashes)) ?? Data()
    }

    private static func tool(_ name: String, _ description: String, _ required: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [String: Any]()]
        if let required {
            schema["properties"] = [required: ["type": "string"]]
            schema["required"] = [required]
        }
        return ["name": name, "description": description, "inputSchema": schema,
                "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    /// The answer to one message, or nil for a notification (or a blank line), which gets none.
    func respond(_ line: Data) -> Data? {
        guard line.contains(where: { ![32, 9, 13].contains($0) }) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed) else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let request = parsed as? [String: Any]
        let id = request?["id"]
        let validID = id == nil || id is String || (id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true
        func reply(_ key: String, _ value: [String: Any]) -> Data {
            Self.encode(["jsonrpc": "2.0", "id": (validID ? id : nil) ?? NSNull(), key: value])
        }
        guard validID, request?["jsonrpc"] as? String == "2.0", let method = request?["method"] as? String else {
            return reply("error", ["code": -32600, "message": "Invalid request"])
        }
        guard id != nil else { return nil }
        let params = request?["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return reply("result", ["protocolVersion": Self.versions.contains(requested) ? requested : Self.versions[0],
                                    "serverInfo": ["name": "oatcake", "version": "1.0.0"], "capabilities": ["tools": [:]]])
        case "ping": return reply("result", [:])
        case "tools/list":
            return reply("result", ["tools": [
                Self.tool("browse_meetings", "List all folders and saved meetings, with their library-relative paths."),
                Self.tool("search_meetings", "Find meetings containing all words in the query, across titles and meeting documents.", "query"),
                Self.tool("read_meeting", "Read a saved meeting's summary, transcript, notes and to-dos by its library-relative path.", "path"),
                Self.tool("list_todos", "List open and completed to-dos, including Oatcake's standalone list.")
            ]])
        case "tools/call":
            guard let name = params["name"] as? String, let keys = Self.arguments[name] else {
                return reply("error", ["code": -32602, "message": "Unknown or missing tool name"])
            }
            if let args = params["arguments"], !(args is [String: Any]) {
                return reply("error", ["code": -32602, "message": "Tool arguments must be an object"])
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard Set(args.keys) == Set(keys), args.values.allSatisfy({ $0 is String }) else {
                return reply("error", ["code": -32602, "message": "Invalid tool arguments"])
            }
            return reply("result", toolResult(name, args))
        default: return reply("error", ["code": -32601, "message": "Method not found"])
        }
    }

    /// A tool's result, or why it can't be had, which the app shows to whoever asked.
    private func toolResult(_ name: String, _ args: [String: Any]) -> [String: Any] {
        func failure(_ text: String) -> [String: Any] { ["isError": true, "content": [["type": "text", "text": text]]] }
        let changed = "The Meetings folder has changed or can’t be read. Check it in Oatcake’s Settings › Storage, then turn “Let other apps read my meetings” off and on again."
        guard let config = loadConfig() else {
            return failure("Oatcake’s settings couldn’t be read. Open Oatcake and check Settings › Storage.")
        }
        guard config.mcpEnabled else {
            return failure("Reading meetings is turned off in Oatcake’s Settings › Storage (“Let other apps read my meetings”).")
        }
        guard let approved = config.mcpApprovedRoot else { return failure(changed) }
        let library: MeetingMCP
        if let open = self.library, open.serves(config.meetingsRoot, approved: approved) {
            library = open
        } else {
            self.library = nil
            guard let opened = try? MeetingMCP(root: config.meetingsRoot, approved: approved) else { return failure(changed) }
            self.library = opened
            library = opened
        }
        let result = library.rootStillSelected() ? library.call(name, args) : nil
        beforeReply()
        // Checked again after reading: a folder swapped in meanwhile mustn't have been read from.
        guard library.rootStillSelected() else {
            self.library = nil
            return failure(changed)
        }
        guard let result else { return failure("Invalid input or meeting unavailable.") }
        return ["content": [["type": "text", "text": String(decoding: Self.encode(result), as: UTF8.self)]], "structuredContent": result]
    }
}

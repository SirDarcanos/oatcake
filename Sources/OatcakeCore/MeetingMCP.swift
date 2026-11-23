import Foundation
import Darwin
import CoreFoundation

/// The MCP view exposes only the saved meeting documents, never recordings or app settings.
final class MeetingMCP: Sendable {
    private let fd: Int32
    private let configuredPath: String
    let identity: MCPServer.RootIdentity
    static let versions = ["2025-11-25", "2025-06-18"]
    private static let files = ["summary", "transcript", "notes", "todo"]
    private static let arguments = ["browse_meetings": [], "search_meetings": ["query"], "read_meeting": ["path"], "list_todos": []]

    init(root: URL, approved: MCPServer.RootIdentity?) throws {
        let configuredPath = root.standardizedFileURL.path
        let fd = open(configuredPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        var identity = stat()
        guard fd >= 0, fstat(fd, &identity) == 0 else {
            if fd >= 0 { close(fd) }
            throw OatcakeError("Can’t read the Meetings folder. Choose an accessible folder in Storage.")
        }
        let opened = MCPServer.RootIdentity(identity)
        guard approved == nil || approved == opened else {
            close(fd)
            throw OatcakeError("The Meetings folder has changed. Check the folder in Storage, then turn MCP off and on again.")
        }
        self.fd = fd
        self.configuredPath = configuredPath
        self.identity = opened
    }

    deinit { if fd >= 0 { close(fd) } }

    private static func tool(_ name: String, _ description: String, _ required: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [String: Any]()]
        if let required {
            schema["properties"] = [required: ["type": "string"]]
            schema["required"] = [required]
        }
        return ["name": name, "description": description, "inputSchema": schema,
                "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    func respond(_ data: Data) -> Data? {
        func encode(_ value: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let request = parsed as? [String: Any]
        let id = request?["id"]
        let validID = id == nil || id is String || (id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true
        func reply(_ key: String, _ value: [String: Any]) -> Data {
            encode(["jsonrpc": "2.0", "id": (validID ? id : nil) ?? NSNull(), key: value])
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
            let result = rootStillSelected() ? call(name, args) : nil
            let text = result.map { String(decoding: encode($0), as: UTF8.self) } ?? "Invalid input or meeting unavailable."
            var output: [String: Any] = ["content": [["type": "text", "text": text]]]
            guard rootStillSelected() else {
                return reply("result", ["isError": true, "content": [["type": "text", "text": "The Meetings folder changed or is unavailable. Turn MCP off and on again after checking Storage settings."]]])
            }
            if let result { output["structuredContent"] = result } else { output["isError"] = true }
            return reply("result", output)
        default: return reply("error", ["code": -32601, "message": "Method not found"])
        }
    }

    func rootStillSelected() -> Bool {
        var current = stat()
        return lstat(configuredPath, &current) == 0 && current.st_mode & S_IFMT == S_IFDIR && MCPServer.RootIdentity(current) == identity
    }

    private func call(_ name: String, _ args: [String: Any]) -> [String: Any]? {
        if name == "read_meeting" {
            guard let path = args["path"] as? String else { return nil }
            return atMeeting(fd, Array(path.utf8.split(separator: 47, omittingEmptySubsequences: false))[...]) { dir in
                guard file(dir, "meeting.json") != nil else { return nil }
                return ["path": path, "documents": documents(dir)]
            }
        }
        let words = (args["query"] as? String ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(whereSeparator: \.isWhitespace)
        guard ["browse_meetings", "search_meetings", "list_todos"].contains(name), name != "search_meetings" || !words.isEmpty else { return nil }
        var folders: [String] = [], meetings: [[String: Any]] = [], todos: [[String: Any]] = []
        func appendTodos(_ dir: Int32, _ path: String, _ title: String) {
            for item in parseTodos(string(dir, "todo.md") ?? "") {
                todos.append(["path": path, "title": title, "text": item.text, "done": item.done,
                              "owner": item.owner, "due": item.due])
            }
        }
        func walk(_ dir: Int32, _ path: String, _ depth: Int) {
            guard depth < 128 else { return }
            // A fresh open has its own directory cursor; dup would share it with the pinned root.
            let cursor = openat(dir, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard cursor >= 0 else { return }
            guard let stream = fdopendir(cursor) else { close(cursor); return }
            defer { closedir(stream) }
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                if !name.isEmpty, !name.hasPrefix(".") { names.append(name) }
            }
            for namePart in names.sorted() {
                let child = openat(dir, namePart, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { continue }
                defer { close(child) }
                let next = path.isEmpty ? namePart : path + "/" + namePart
                if let meta = file(child, "meeting.json") {
                    let decoded = try? JSONDecoder().decode(MeetingMeta.self, from: meta)
                    let title = decoded?.title ?? namePart
                    if name == "list_todos" { appendTodos(child, next, title); continue }
                    if name == "search_meetings" {
                        let haystack = ([next, title] + Array(documents(child).values)).joined(separator: "\n")
                            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        guard words.allSatisfy({ haystack.contains($0) }) else { continue }
                    }
                    var result: [String: Any] = ["path": next, "title": title]
                    result["startedAt"] = decoded?.startedAt
                    meetings.append(result)
                } else {
                    folders.append(next)
                    walk(child, next, depth + 1)
                }
            }
        }
        if name == "list_todos" { appendTodos(fd, "", "To-dos") }
        walk(fd, "", 0)
        switch name {
        case "list_todos": return ["todos": todos]
        case "search_meetings": return ["meetings": meetings]
        default: return ["folders": folders, "meetings": meetings]
        }
    }

    private func atMeeting<T>(_ dir: Int32, _ path: ArraySlice<Substring.UTF8View>, _ body: (Int32) -> T?) -> T? {
        guard let part = path.first else { return body(dir) }
        guard !part.isEmpty, part.first != 46, path.count <= 128, !part.contains(0), !part.contains(47) else { return nil }
        let child = openat(dir, String(decoding: part, as: UTF8.self), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { return nil }
        defer { close(child) }
        if path.count > 1, file(child, "meeting.json") != nil { return nil }
        return atMeeting(child, path.dropFirst(), body)
    }

    private func documents(_ dir: Int32) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.files.compactMap { name in
            string(dir, name + ".md").map { (name, $0) }
        })
    }

    private func string(_ dir: Int32, _ name: String) -> String? {
        file(dir, name).map { String(decoding: $0, as: UTF8.self) }
    }

    // Resolve relative to an already-open directory, and never follow symlinks even if a file is replaced during a request.
    private func file(_ dir: Int32, _ name: String) -> Data? {
        let fd = openat(dir, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}

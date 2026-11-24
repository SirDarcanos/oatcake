import Foundation
import Testing
@testable import OatcakeCore

struct MCPTests {
    @Test func settingDefaultsOffAndRoundTrips() throws {
        var config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(!config.mcpEnabled)
        config.mcpEnabled = true
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(restored.mcpEnabled)
    }

    @Test func configurationNamesTheExecutableAndFlag() throws {
        let json = MCPServer.configuration(executable: "/Applications/Oatcake.app/Contents/MacOS/Oatcake")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let server = try #require((parsed["mcpServers"] as? [String: Any])?["oatcake"] as? [String: Any])
        #expect(server["command"] as? String == "/Applications/Oatcake.app/Contents/MacOS/Oatcake")
        #expect(server["args"] as? [String] == ["--mcp"])
        #expect(server.count == 2)
    }

    /// A Meetings folder with one meeting, a nested folder, and the things that mustn't be read:
    /// a draft, a backup inside a meeting, a symlinked folder and a symlinked file pointing outside.
    private struct Library {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var root: URL { fixture.appendingPathComponent("Meetings") }
        var outside: URL { fixture.appendingPathComponent("Private") }

        init() throws {
            let fm = FileManager.default
            let meeting = root.appendingPathComponent("Projects/Launch")
            try fm.createDirectory(at: meeting, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try write("meeting.json", #"{"title":"Launch review","startedAt":"2026-11-20T14:00:00Z"}"#, in: meeting)
            try write("summary.md", "Launch approved", in: meeting)
            try (Data("Jane Doe: Schedule the launch".utf8) + Data([255])).write(to: meeting.appendingPathComponent("transcript.md"))
            try write("notes.md", "Budget approved", in: meeting)
            try write("todo.md", "- [ ] Send agenda\n- [x] Close review", in: meeting)
            try write("todo.md", "- [x] Read notes", in: root)
            try write("draft.md", "PRIVATE DRAFT", in: meeting)
            let backup = meeting.appendingPathComponent("Backup")
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            try write("meeting.json", "{}", in: backup)
            try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: false)
            try write("meeting.json", "{}", in: root.appendingPathComponent(".hidden"))
            try write("meeting.json", "{}", in: outside)
            try write("summary.md", "PRIVATE EXTERNAL", in: outside)
            try fm.createSymbolicLink(at: root.appendingPathComponent("Outside"), withDestinationURL: outside)
            try fm.createDirectory(at: root.appendingPathComponent("Linked"), withIntermediateDirectories: false)
            try write("meeting.json", "{}", in: root.appendingPathComponent("Linked"))
            try fm.createSymbolicLink(at: root.appendingPathComponent("Linked/notes.md"), withDestinationURL: outside.appendingPathComponent("summary.md"))
        }

        func write(_ file: String, _ text: String, in dir: URL) throws {
            try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: fixture) }

        func config(enabled: Bool = true, approved: MCPServer.RootIdentity?) -> Config {
            var config = Config.defaults()
            config.outputDir = root.path
            config.mcpEnabled = enabled
            config.mcpApprovedRoot = approved
            return config
        }
    }

    /// Runs the server over the real line transport: each request on its own line, end of input after
    /// the last. Returns the lines it wrote.
    private func session(_ server: MCPServer, _ requests: [String], raw: Data? = nil) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in"), output = dir.appendingPathComponent("out")
        try (raw ?? Data(requests.map { $0 + "\n" }.joined().utf8)).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let reading = try FileHandle(forReadingFrom: input), writing = try FileHandle(forWritingTo: output)
        server.serve(input: reading.fileDescriptor, output: writing.fileDescriptor)
        try reading.close()
        try writing.close()
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.isEmpty || text.hasSuffix("\n"))
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    private func call(_ id: Int, _ name: String, _ arguments: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
    }

    private func result(_ line: String) throws -> [String: Any] {
        let rpc = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try #require(rpc["result"] as? [String: Any])
    }

    private func text(_ line: String) throws -> String {
        let content = try #require(try result(line)["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func failed(_ line: String) throws -> Bool { try result(line)["isError"] as? Bool == true }

    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#

    @Test func stdioSessionAndLibraryBoundary() throws {
        let library = try Library()
        defer { library.remove() }
        let config = library.config(approved: try MCPServer.RootIdentity.approve(library.root))
        let server = MCPServer(loadConfig: { config })
        let lines = try session(server, [
            initialize,
            initialize.replacingOccurrences(of: "2025-11-25", with: "2025-06-18").replacingOccurrences(of: #""id":1"#, with: #""id":2"#),
            initialize.replacingOccurrences(of: "2025-11-25", with: "2025-03-26").replacingOccurrences(of: #""id":1"#, with: #""id":3"#),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
            call(5, "browse_meetings"),
            call(6, "search_meetings", #"{"query":"budget agenda"}"#),
            call(7, "search_meetings", #"{"query":"PRIVATE"}"#),
            call(8, "read_meeting", #"{"path":"Projects/Launch"}"#),
            call(9, "list_todos"),
            "{not json",
            #"{"jsonrpc":"2.0","id":true,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"list_todos","arguments":[]}}"#,
            call(11, "write_meeting"),
            call(12, "list_todos", #"{"filter":"open"}"#),
            #"{"jsonrpc":"2.0","id":13,"method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":14,"method":"ping"}"#,
        ])
        // One line for every message with an id, none for the notification or the blank line.
        #expect(lines.count == 16)
        guard lines.count == 16 else { return }
        #expect(lines[0].contains(#""protocolVersion":"2025-11-25""#))
        #expect(lines[1].contains(#""protocolVersion":"2025-06-18""#))
        #expect(lines[2].contains(#""protocolVersion":"2025-11-25""#))
        #expect(["browse_meetings", "search_meetings", "read_meeting", "list_todos"].allSatisfy { lines[3].contains($0) })
        #expect(lines[3].contains(#""id":"list""#))
        let tree = try text(lines[4])
        #expect(tree.contains("Projects/Launch") && !tree.contains("Outside") && !tree.contains("Backup") && !tree.contains(".hidden"))
        #expect(try text(lines[5]).contains("Projects/Launch"))
        #expect(try !text(lines[6]).contains("Linked"))
        let read = try text(lines[7])
        #expect(["Launch approved", "Schedule the launch", "Budget approved", "Send agenda"].allSatisfy { read.contains($0) })
        #expect(!read.contains("PRIVATE DRAFT"))
        let structured = try #require(try result(lines[8])["structuredContent"] as? [String: Any])
        let items = try #require(structured["todos"] as? [[String: Any]])
        #expect(items.count == 3)
        for (text, done, path) in [("Send agenda", false, "Projects/Launch"), ("Close review", true, "Projects/Launch"), ("Read notes", true, "")] {
            #expect(items.contains { $0["text"] as? String == text && $0["done"] as? Bool == done && $0["path"] as? String == path })
        }
        #expect(lines[9].contains("-32700") && lines[9].contains(#""id":null"#))
        #expect(lines[10].contains("-32600"))
        #expect(lines[11].contains("-32602"))
        #expect(lines[12].contains("-32602"))
        #expect(lines[13].contains("-32602"))
        #expect(lines[14].contains("-32601"))
        #expect(lines[15].contains(#""id":14"#) && lines[15].contains(#""result":{}"#))
        // The last message is answered even without its newline.
        #expect(try session(server, [], raw: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)).count == 1)

        // Nothing outside the folder, nothing hidden, nothing past a meeting, nothing through a link.
        let refused = try session(server, [
            #"{"path":"../Private"}"#, #"{"path":"/etc"}"#, #"{"path":"Outside"}"#, #"{"path":".hidden"}"#,
            #"{"path":"Projects/Launch/Backup"}"#, #"{"path":"Projects/́Launch"}"#, #"{"path":""}"#, #"{"path":"Projects//Launch"}"#,
        ].enumerated().map { call($0.offset, "read_meeting", $0.element) })
        #expect(refused.count == 8)
        #expect(try refused.allSatisfy(failed))
        let linked = try session(server, [call(1, "read_meeting", #"{"path":"Linked"}"#)])
        #expect(try !failed(linked[0]) && !text(linked[0]).contains("PRIVATE EXTERNAL"))
    }

    /// The settings are read for every call: off, unreadable, or not approved, nothing is read.
    @Test func offOrUnapprovedReadsNothing() throws {
        let library = try Library()
        defer { library.remove() }
        let approved = try MCPServer.RootIdentity.approve(library.root)
        var current: Config? = library.config(enabled: false, approved: approved)
        let server = MCPServer(loadConfig: { current })
        let browse = call(1, "browse_meetings")

        let off = try session(server, [initialize, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, browse])
        #expect(off.count == 3 && off[0].contains("protocolVersion") && off[1].contains("browse_meetings"))
        #expect(try failed(off[2]) && text(off[2]).contains("turned off") && !off[2].contains("Projects"))

        current = nil
        #expect(try text(session(server, [browse])[0]).contains("settings couldn’t be read"))

        current = library.config(approved: nil)
        let unapproved = try session(server, [browse])[0]
        #expect(try failed(unapproved) && !unapproved.contains("Projects"))

        current = library.config(approved: approved)
        #expect(try !failed(session(server, [browse])[0]))

        // Turned off while a session is running: the next call is refused.
        current = library.config(enabled: false, approved: approved)
        #expect(try failed(session(server, [browse])[0]))
    }

    /// A folder put in the Meetings folder's place isn't read, before or during a call, until it's approved.
    @Test func replacedFolderIsRefusedUntilApproved() throws {
        let library = try Library()
        defer { library.remove() }
        let fm = FileManager.default
        let approved = try MCPServer.RootIdentity.approve(library.root)
        var current = library.config(approved: approved)
        let swapDuringCall = Mutex(false)
        let moved = library.fixture.appendingPathComponent("Original")
        let server = MCPServer(loadConfig: { current }, beforeReply: {
            guard swapDuringCall.value else { return }
            do {
                try fm.moveItem(at: library.root, to: moved)
                try fm.createSymbolicLink(at: library.root, withDestinationURL: moved)
            } catch { Issue.record("Could not replace the folder: \(error)") }
        })
        let browse = call(1, "browse_meetings")
        #expect(try !failed(session(server, [browse])[0]))

        // Swapped for a link to itself after the folder was read and before the reply.
        swapDuringCall.value = true
        let during = try session(server, [browse])[0]
        #expect(try failed(during) && !during.contains("Projects"))
        swapDuringCall.value = false
        #expect(try failed(session(server, [browse])[0]))

        // Another folder in its place.
        try fm.removeItem(at: library.root)
        try fm.createDirectory(at: library.root.appendingPathComponent("Replacement"), withIntermediateDirectories: true)
        try library.write("meeting.json", "{}", in: library.root.appendingPathComponent("Replacement"))
        #expect(try failed(session(server, [browse])[0]))

        // Approved again (turned off and on in Settings): the new folder is read, and the old one isn't.
        current.mcpApprovedRoot = try MCPServer.RootIdentity.approve(library.root)
        let switched = try text(session(server, [browse])[0])
        #expect(switched.contains("Replacement") && !switched.contains("Projects/Launch"))

        // Another Meetings folder chosen in Settings: followed without restarting the server.
        current.outputDir = moved.path
        current.mcpApprovedRoot = try MCPServer.RootIdentity.approve(moved)
        let chosen = try text(session(server, [browse])[0])
        #expect(chosen.contains("Projects/Launch") && !chosen.contains("Replacement"))
    }

    @Test func oversizedMessageIsSkipped() throws {
        let server = MCPServer(loadConfig: { nil })
        let huge = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":""# + String(repeating: "x", count: MCPServer.lineLimit + 10) + "\"}}"
        let lines = try session(server, [huge, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#])
        #expect(lines.count == 2)
        #expect(lines.first?.contains("Message too large") == true)
        #expect(lines.last?.contains(#""id":2"#) == true)
    }

    @Test func savedConfigOnlyReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        #expect(MCPServer.savedConfig(file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("not json".utf8).write(to: file)
        #expect(MCPServer.savedConfig(file) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"])
    }
}

/// A value the test and the server's hook share.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

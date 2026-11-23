import Foundation
import Testing
import os
@testable import OatcakeCore

struct MCPTests {
    @Test func chunkedFraming() {
        #expect(MCPServer.decodeChunks(Data("2\r\n{}\r\n0\r\n\r\n".utf8)) == .complete(Data("{}".utf8)))
        #expect(MCPServer.decodeChunks(Data("2;name=value\r\n{}\r\n0\r\nTrailer: example\r\n\r\n".utf8)) == .complete(Data("{}".utf8)))
        #expect(MCPServer.decodeChunks(Data("2\r\n{".utf8)) == .incomplete)
        #expect(MCPServer.decodeChunks(Data("2\r\n{}\r\n0\r\n\r\nextra".utf8)) == .invalid)
        #expect(MCPServer.decodeChunks(Data("100001\r\n".utf8)) == .tooLarge)
    }

    @Test func settingDefaultsOffAndRoundTrips() throws {
        var config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(!config.mcpEnabled)
        config.mcpEnabled = true
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(restored.mcpEnabled)
    }

    @Test(.timeLimit(.minutes(1))) func streamableHTTPAndLibraryBoundary() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("Meetings")
        let meeting = root.appendingPathComponent("Projects/Launch")
        let outside = fixture.appendingPathComponent("Private")
        let fm = FileManager.default
        try fm.createDirectory(at: meeting, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        func write(_ file: String, _ text: String, in dir: URL) throws {
            try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try write("meeting.json", #"{"title":"Launch review"}"#, in: meeting)
        try write("summary.md", "Launch approved", in: meeting)
        try (Data("Jane Doe: Schedule the launch".utf8) + Data([255])).write(to: meeting.appendingPathComponent("transcript.md"))
        try write("notes.md", "Budget approved", in: meeting)
        try write("todo.md", "- [ ] Send agenda\n- [x] Close review", in: meeting)
        try write("todo.md", "- [x] Read notes", in: root)
        try write("draft.md", "PRIVATE DRAFT", in: meeting)
        let backup = meeting.appendingPathComponent("Backup")
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        try write("meeting.json", "{}", in: backup)
        try write("meeting.json", "{}", in: outside)
        try write("summary.md", "PRIVATE EXTERNAL", in: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Outside"), withDestinationURL: outside)
        try fm.createDirectory(at: root.appendingPathComponent("Linked"), withIntermediateDirectories: false)
        try write("meeting.json", "{}", in: root.appendingPathComponent("Linked"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Linked/notes.md"), withDestinationURL: outside.appendingPathComponent("summary.md"))

        let (updates, continuation) = AsyncStream<MCPServer.Status>.makeStream()
        let approved = try MCPServer.RootIdentity.approve(root)
        let moveBeforeReply = OSAllocatedUnfairLock(initialState: false)
        let moved = fixture.appendingPathComponent("Original")
        let server = try MCPServer(root: root, approved: approved, token: "test-token", port: 0, beforeReply: {
            guard moveBeforeReply.withLock({ $0 }) else { return }
            do {
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
            } catch { Issue.record("Could not replace fixture root: \(error)") }
        }) { continuation.yield($0) }
        defer { server.stop(); continuation.finish() }
        var iterator = updates.makeAsyncIterator()
        guard case .running(let port) = await iterator.next() else { Issue.record("Listener failed to start"); return }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ json: String? = nil, token: String? = "test-token", origin: String? = nil, scheme: String = "Bearer") async throws -> (Int, String) {
            var req = URLRequest(url: endpoint, timeoutInterval: 3)
            if let token { req.setValue(scheme + " " + token, forHTTPHeaderField: "Authorization") }
            if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let json {
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = Data(json.utf8)
            }
            let (data, response) = try await session.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let initRPC = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        #expect(try await request(initRPC, token: nil).0 == 401)
        #expect(try await request(initRPC, token: "incorrect").0 == 401)
        #expect(try await request(initRPC, origin: "https://example.org").0 == 403)
        #expect(try await request().0 == 405)
        let (code, initialized) = try await request(initRPC)
        #expect(code == 200 && initialized.contains("2025-11-25"))
        let older = try await request(initRPC.replacingOccurrences(of: "2025-11-25", with: "2025-06-18"), scheme: "bearer")
        #expect(older.0 == 200 && older.1.contains("2025-06-18"))
        let unsupported = try await request(initRPC.replacingOccurrences(of: "2025-11-25", with: "2025-03-26"))
        #expect(unsupported.0 == 200 && unsupported.1.contains("2025-11-25"))
        #expect(try await request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0 == 202)
        let (_, listed) = try await request(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(["browse_meetings", "search_meetings", "read_meeting", "list_todos"].allSatisfy { listed.contains($0) })
        func call(_ name: String, arguments: String = "{}") async throws -> String {
            let (status, result) = try await request(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
            #expect(status == 200)
            return result.replacingOccurrences(of: #"\/"#, with: "/")
        }
        let tree = try await call("browse_meetings")
        #expect(tree.contains("Projects/Launch") && !tree.contains("Outside") && !tree.contains("Backup"))
        #expect(try await call("read_meeting", arguments: #"{"path":"Projects/Launch/Backup"}"#).contains("isError"))
        #expect(try await call("search_meetings", arguments: #"{"query":"budget agenda"}"#).contains("Projects/Launch"))
        #expect(try await !call("search_meetings", arguments: #"{"query":"PRIVATE"}"#).contains("Linked"))
        let read = try await call("read_meeting", arguments: #"{"path":"Projects/Launch"}"#)
        #expect(["Launch approved", "Schedule the launch", "Budget approved", "Send agenda"].allSatisfy { read.contains($0) })
        #expect(!read.contains("PRIVATE DRAFT"))
        #expect(try await !call("read_meeting", arguments: #"{"path":"Linked"}"#).contains("PRIVATE EXTERNAL"))
        #expect(try await call("read_meeting", arguments: #"{"path":"../Private"}"#).contains("isError"))
        #expect(try await call("read_meeting", arguments: #"{"path":"Outside"}"#).contains("isError"))
        #expect(try await call("read_meeting", arguments: #"{"path":"Projects/\u0301Launch"}"#).contains("isError"))
        #expect(try await request(#"{"jsonrpc":"2.0","id":true,"method":"tools/list"}"#).1.contains("-32600"))
        #expect(try await request(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_todos","arguments":[]}}"#).1.contains("-32602"))
        let todos = try await call("list_todos")
        let rpc = try #require(JSONSerialization.jsonObject(with: Data(todos.utf8)) as? [String: Any])
        let result = try #require(rpc["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let items = try #require(structured["todos"] as? [[String: Any]])
        #expect(items.count == 3)
        for (text, done, path) in [("Send agenda", false, "Projects/Launch"), ("Close review", true, "Projects/Launch"), ("Read notes", true, "")] {
            #expect(items.contains { $0["text"] as? String == text && $0["done"] as? Bool == done && $0["path"] as? String == path })
        }
        #expect(try await call("write_meeting").contains("-32602"))
        #expect(try await call("list_todos", arguments: #"{"filter":"open"}"#).contains("-32602"))
        // Replace the root after the result is produced but before the transport can send it.
        let browseRPC = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"browse_meetings"}}"#
        moveBeforeReply.withLock { $0 = true }
        let (staleStatus, staleBody) = try await request(browseRPC)
        #expect(staleStatus == 503 && staleBody.isEmpty)
        moveBeforeReply.withLock { $0 = false }
        try fm.removeItem(at: root)
        try fm.moveItem(at: moved, to: root)
        let restored = try await request(browseRPC)
        #expect(restored.0 == 503 && restored.1.isEmpty)
        try fm.moveItem(at: root, to: moved)
        try fm.createDirectory(at: root.appendingPathComponent("Replacement"), withIntermediateDirectories: true)
        try write("meeting.json", "{}", in: root.appendingPathComponent("Replacement"))
        let pinned = try await request(browseRPC)
        #expect(pinned.0 == 503 && pinned.1.isEmpty)
        server.stop()
        await #expect(throws: URLError.self) { try await request(initRPC) }
        let (replacementUpdates, replacementContinuation) = AsyncStream<MCPServer.Status>.makeStream()
        let persisted = try JSONDecoder().decode(MCPServer.RootIdentity.self, from: JSONEncoder().encode(approved))
        #expect(throws: OatcakeError.self) {
            try MCPServer(root: root, approved: persisted, token: "test-token", port: port) { _ in }
        }
        let newApproval = try MCPServer.RootIdentity.approve(root)
        let replacement = try MCPServer(root: root, approved: newApproval, token: "test-token", port: port) { replacementContinuation.yield($0) }
        defer { replacement.stop(); replacementContinuation.finish() }
        var replacementIterator = replacementUpdates.makeAsyncIterator()
        guard case .running(port) = await replacementIterator.next() else { Issue.record("Could not restart on the same port"); return }
        let switched = try await call("browse_meetings")
        #expect(switched.contains("Replacement") && !switched.contains("Projects/Launch"))
    }
}

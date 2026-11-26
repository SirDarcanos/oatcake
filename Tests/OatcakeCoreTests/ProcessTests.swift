import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ProcessTests {
    /// Oatcake's helpers (and the language model's server) don't get the calendar's private address.
    @Test func childEnvironments() {
        let name = CalendarSource.environmentVariable
        let before = ProcessInfo.processInfo.environment[name]
        setenv(name, "https://calendar.example.com/private.ics", 1)
        defer { if let before { setenv(name, before, 1) } else { unsetenv(name) } }
        #expect(ShellEnvironment.childEnvironment()[name] == nil)
        #expect(ShellEnvironment.childEnvironment()["PATH"] == ProcessInfo.processInfo.environment["PATH"])
    }

    /// The system's tools are run with their output read, their failures said, and a limit on how long they get.
    @Test func runsTools() throws {
        #expect(try runCapturing("/bin/echo", ["hello"]) == "hello\n")
        #expect(throws: OatcakeError("false exited 1")) { try runCapturing("/usr/bin/false", []) }
        // What the tool said on its way out is the message.
        #expect(throws: OatcakeError.self) { try runCapturing("/bin/ls", ["/no/such/folder"]) }
        let started = Date()
        #expect(throws: OatcakeError("sleep took too long and was stopped.")) { try runCapturing("/bin/sleep", ["30"], timeout: 0.3) }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// Twice as many at once as there are processor cores, each from a task. Every thread Swift's tasks
    /// run on is then inside runCapturing, so nothing it waits for may need another of them: on a
    /// machine with few cores (a build machine has three) that used to stop the tests for good.
    @Test func manyAtOnce() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<count { group.addTask { try runCapturing("/bin/echo", ["\(i)"]) } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(outputs.count == count)
    }

    /// Lines a helper prints, as ChildProcess hands them over (from the pipe's own thread).
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        var lines: [String] { lock.withLock { all } }
        func add(_ line: String) { lock.withLock { all.append(line) } }
    }

    /// A helper's output arrives whole, its last line included, however close to its exit that line
    /// is printed: the analysis helper's reason for failing is its last line before it exits.
    @Test func helperOutputArrivesWhole() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let script = #"i=0; while [ $i -lt 300 ]; do echo "line $i"; i=$((i+1)); done; echo "went wrong" >&2; printf '{"error":"x"}'; exit 3"#
        let expected = (0..<300).map { "line \($0)" } + [#"{"error":"x"}"#]
        for _ in 0..<150 {
            let heard = Heard()
            let result = try await ChildProcess.run(sh, ["-c", script], onLine: { heard.add($0) })
            #expect(result.status == 3 && result.stderr == "went wrong\n")
            #expect(heard.lines == expected)
            #expect(result.stdout == expected.joined(separator: "\n"))
        }
        // Without onLine, the output is still collected.
        let quiet = try await ChildProcess.run(sh, ["-c", "echo one; echo two"])
        #expect(quiet.status == 0 && quiet.stdout == "one\ntwo\n" && quiet.stderr.isEmpty)
    }

    /// A helper that's stopped, or ends on a signal, says so with the signal's number below zero; one
    /// that can't be started throws.
    @Test func helperStoppedOrMissing() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let started = Date()
        // exec: the shell becomes sleep, so nothing else is left holding its output open.
        let stopped = try await ChildProcess.run(sh, ["-c", "exec sleep 30"], onStart: { $0.terminate() })
        #expect(stopped.status == -SIGTERM && Date().timeIntervalSince(started) < 10)
        #expect(try await ChildProcess.run(sh, ["-c", "kill -KILL $$"]).status == -SIGKILL)
        await #expect(throws: (any Error).self) { try await ChildProcess.run(URL(fileURLWithPath: "/no/such/helper"), []) }
    }

    /// A pid file is only believed when the process is running and is the program it should be.
    @Test func whoseProcess() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var path = [CChar](repeating: 0, count: 4096)
        proc_pidpath(getpid(), &path, UInt32(path.count))
        let mine = URL(fileURLWithPath: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }).lastPathComponent
        #expect(isRunning(getpid(), program: mine) && !isRunning(getpid(), program: "oatcake-recorder") && !isRunning(1, program: mine) && !isRunning(-5, program: mine))
        #expect(runningPid(in: file, program: mine) == nil)
        try "\(getpid())\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(runningPid(in: file, program: mine) == getpid() && runningPid(in: file, program: "llama-server") == nil)
        try "not a number".write(to: file, atomically: true, encoding: .utf8)
        #expect(runningPid(in: file, program: mine) == nil)
    }
}

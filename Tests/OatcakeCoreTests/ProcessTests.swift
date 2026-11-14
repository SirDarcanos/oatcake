import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ProcessTests {
    /// Oatcake's helpers (and the language model's server) don't get the calendar's private address.
    @Test func childEnvironments() {
        let name = "OATCAKE_CALENDAR_URL"
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

// Running other programs: Oatcake's own helpers (ChildProcess), and the system's tools (runCapturing).

import Foundation

/// What Oatcake's own helper processes are started with: this process's environment, without the
/// calendar's private address, which is none of their business.
public enum ShellEnvironment {
    public static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OATCAKE_CALENDAR_URL")
        return env
    }
}

/// How long one of the system's tools (ditto, unzip, sqlite3, codesign, open) gets before it's stopped.
public let toolTimeout: TimeInterval = 120

/// Runs a command and returns its standard output; throws with its error output when it fails, or
/// when it's still going after `timeout` seconds (it's stopped then, so nothing waits on it for ever).
@discardableResult
public func runCapturing(_ executable: String, _ arguments: [String], timeout: TimeInterval = toolTimeout) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // This blocks the thread it's called on until the tool has finished, and what it waits for mustn't
    // need a thread from the pool that thread came from: called from as many tasks as the Mac has
    // cores, there would be none left and nothing would ever finish. So the time limit has a queue of
    // its own, and the error output a thread of its own.
    let stopped = Locked(false)
    DispatchQueue(label: "oatcake.tool-time-limit").asyncAfter(deadline: .now() + timeout) {
        if process.isRunning {
            stopped.value = true
            process.terminate()
        }
    }
    // Both pipes are read before waiting (one on another thread), so a full pipe can't stall the process.
    let errData = Locked(Data())
    let errRead = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        errData.value = err.fileHandleForReading.readDataToEndOfFile()
        errRead.signal()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    errRead.wait()
    process.waitUntilExit()
    let name = URL(fileURLWithPath: executable).lastPathComponent
    if stopped.value { throw OatcakeError("\(name) took too long and was stopped.") }
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errData.value, as: UTF8.self).trimmed
        throw OatcakeError(message.isEmpty ? "\(name) exited \(process.terminationStatus)" : message)
    }
    return String(decoding: outData, as: UTF8.self)
}

/// A value set on one thread and read on another, behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The process ID a file holds, when that process is still running and is `name` (isRunning, which
/// the recorder uses too, is RecorderContract's).
func runningPid(in file: URL, program name: String) -> pid_t? {
    guard let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text.trimmed), isRunning(pid, program: name) else { return nil }
    return pid
}

/// What Oatcake's own program is run with to be one of its helpers rather than the app (the menu
/// bar's is MenuBarLink.flag). Each is followed by the recording's folder.
public enum HelperMode {
    /// Analyses one recording.
    public static let analyse = "--analyse"
    /// Transcribes a call while it's being recorded.
    public static let live = "--live"
    /// Lets the app that started it read the saved meetings over MCP (MCPServer).
    public static let mcp = "--mcp"
}

/// A helper process with its output collected, line by line if wanted, without blocking a thread.
public enum ChildProcess {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// A helper that's running, for whoever started it to stop. Only stopping is offered, which is
    /// safe from any thread (it sends the process a signal, and does nothing once it has gone).
    public struct Handle: @unchecked Sendable {
        let process: Process
        public func terminate() { process.terminate() }
    }

    /**
     * Runs a helper to the end. It's over when the process has exited and both its pipes have said
     * end-of-file to their own readers: reading what was left from the termination handler instead
     * raced a reader that had the helper's last piece of output in hand, and lost its last line (an
     * analysis helper's reason for failing, say).
     */
    public static func run(_ executable: URL, _ arguments: [String],
                           onStart: (@Sendable (Handle) -> Void)? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ShellEnvironment.childEnvironment()
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            let collected = Collected(onLine: onLine, continuation: continuation)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collected.ended(.out)
                } else {
                    collected.appendOut(data)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collected.ended(.err)
                } else {
                    collected.appendErr(data)
                }
            }
            process.terminationHandler = { p in
                collected.exited(p.terminationReason == .uncaughtSignal ? -p.terminationStatus : p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collected.failed(error)
                return
            }
            onStart?(Handle(process: process))
        }
    }

    // Sendable by its lock: output arrives on each pipe's own thread, and the exit on another.
    private final class Collected: @unchecked Sendable {
        enum Stream { case out, err }
        private let lock = NSLock()
        private let onLine: (@Sendable (String) -> Void)?
        private var continuation: CheckedContinuation<Result, Error>?
        private var outData = Data()
        private var errData = Data()
        private var lines = LineBuffer()
        private var open: Set<Stream> = [.out, .err]
        private var status: Int32?

        init(onLine: (@Sendable (String) -> Void)?, continuation: CheckedContinuation<Result, Error>) {
            self.onLine = onLine
            self.continuation = continuation
        }

        func appendOut(_ data: Data) {
            let complete = lock.withLock { () -> [String] in
                outData.append(data)
                return onLine == nil ? [] : lines.add(data)
            }
            complete.forEach { onLine?($0) }
        }

        func appendErr(_ data: Data) { lock.withLock { errData.append(data) } }

        /// A pipe has reached its end. Standard output's last line may have had no newline.
        func ended(_ pipe: Stream) {
            let last = lock.withLock { pipe == .out && onLine != nil ? lines.finish() : nil }
            if let last { onLine?(last) }
            finishIfDone { $0.open.remove(pipe) }
        }

        func exited(_ status: Int32) { finishIfDone { $0.status = status } }

        func failed(_ error: Error) {
            lock.withLock { () -> CheckedContinuation<Result, Error>? in
                defer { continuation = nil }
                return continuation
            }?.resume(throwing: error)
        }

        private func finishIfDone(_ change: (Collected) -> Void) {
            let done = lock.withLock { () -> (CheckedContinuation<Result, Error>, Result)? in
                change(self)
                guard open.isEmpty, let status, let continuation else { return nil }
                self.continuation = nil
                return (continuation, Result(status: status, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self)))
            }
            done.map { $0.0.resume(returning: $0.1) }
        }
    }
}

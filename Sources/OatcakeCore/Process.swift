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

/// Whether a process ID is a running copy of the program whose path ends with `name`: a pid file
/// outlives its process when that crashes, and macOS gives process IDs out again.
func isRunning(_ pid: pid_t, program name: String) -> Bool {
    guard pid > 1 else { return false }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
    return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.hasSuffix("/" + name)
}

/// The process ID a file holds, when that process is still running and is `name`.
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

        let collected = Collected()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collected.appendOut(data, onLine: onLine)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.appendErr(data) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Whatever arrived after the last readability callback.
                collected.appendOut(stdout.fileHandleForReading.readDataToEndOfFile(), onLine: onLine)
                collected.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())
                collected.flush(onLine: onLine)
                continuation.resume(returning: Result(status: p.terminationReason == .uncaughtSignal ? -p.terminationStatus : p.terminationStatus,
                                                      stdout: collected.out, stderr: collected.err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            onStart?(Handle(process: process))
        }
    }

    // Sendable by its lock: output arrives on the pipes' own threads and is read from the caller's.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private var pending = Data()
        var out: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
        var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }

        func appendOut(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
            guard !data.isEmpty else { return }
            var lines: [String] = []
            lock.withLock {
                outData.append(data)
                guard onLine != nil else { return }
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending = Data(pending[pending.index(after: newline)...])
                }
            }
            lines.forEach { onLine?($0) }
        }

        func appendErr(_ data: Data) { lock.withLock { errData.append(data) } }

        func flush(onLine: (@Sendable (String) -> Void)?) {
            let rest = lock.withLock { () -> String in
                defer { pending = Data() }
                return String(decoding: pending, as: UTF8.self)
            }
            if !rest.isEmpty { onLine?(rest) }
        }
    }
}

// Oatcake's side of RecorderGate (RecorderContract): the recorder records only when Oatcake asked
// it to. As it starts, the recorder connects here, checks by code signature that it has reached
// Oatcake, and asks about the folder it was told to record into. The answer is yes only for a
// recording Oatcake has just started. Whatever else launches the recorder gets no.

import Foundation
import RecorderContract

// Sendable by its lock: recorders are answered on a thread of the door's own.
public final class RecorderDoor: @unchecked Sendable {
    private let lock = NSLock()
    /// Folders a recorder is expected to ask about, and since when.
    private var wanted: [String: Date] = [:]
    /// A recorder asks within moments of being launched. A yes that nobody has collected by then
    /// (the recorder never started) isn't left standing.
    static let patience: TimeInterval = 60
    private var listening: (fd: Int32, path: String)?
    private let directory: URL

    /// `directory` is where the socket goes: the temporary folder, which only you can read.
    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    deinit {
        if let listening {
            close(listening.fd)
            unlink(listening.path)
        }
    }

    /// The next recorder to ask about this folder is told yes. Returns the socket to ask at.
    public func expect(_ dir: URL) throws -> String {
        try lock.withLock {
            wanted[dir.standardizedFileURL.path] = Date()
            if let listening { return listening.path }
            let path = directory.appendingPathComponent("oatcake-\(getpid())-\(UUID().uuidString.prefix(8)).sock").path
            let fd = try Self.listen(at: path)
            listening = (fd, path)
            Thread.detachNewThread { [weak self] in
                while true {
                    let connection = accept(fd, nil, nil)
                    if connection < 0 {
                        if errno == EINTR { continue }
                        // The socket is no use any more: the next recording gets a new one.
                        self?.stopListening(on: fd)
                        return
                    }
                    guard let self else {
                        close(connection)
                        return
                    }
                    self.answer(connection)
                }
            }
            return path
        }
    }

    /// The recorder never started: one asking about this folder is told no again.
    public func forget(_ dir: URL) {
        lock.withLock { _ = wanted.removeValue(forKey: dir.standardizedFileURL.path) }
    }

    private func stopListening(on fd: Int32) {
        lock.withLock {
            guard listening?.fd == fd, let path = listening?.path else { return }
            close(fd)
            unlink(path)
            listening = nil
        }
    }

    private func answer(_ connection: Int32) {
        defer { close(connection) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // One line: the folder being asked about.
        var question = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while question.count < 4096, !question.contains(0x0A) {
            let got = read(connection, &buffer, buffer.count)
            if got <= 0 { break }
            question.append(contentsOf: buffer[..<got])
        }
        let asked = String(decoding: question, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // One yes for each recording: a second recorder asking about the same folder is told no.
        let yes = !asked.isEmpty && lock.withLock {
            let since = wanted.removeValue(forKey: URL(fileURLWithPath: asked).standardizedFileURL.path)
            return since.map { Date().timeIntervalSince($0) <= Self.patience } ?? false
        }
        let reply = Array(((yes ? RecorderGate.yes : RecorderGate.no) + "\n").utf8)
        _ = reply.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }

    private static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OatcakeError("Couldn’t get ready to start the recorder (\(String(cString: strerror(errno)))).") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw OatcakeError("Couldn’t get ready to start the recorder: the temporary folder’s path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw OatcakeError("Couldn’t get ready to start the recorder (\(why)).")
        }
        return fd
    }
}

import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct RecorderGateTests {
    // The requirement strings are in the form `codesign -d -r -` prints; the hash is made up.
    @Test func whoMayAsk() {
        let release = #"identifier "local.oatcake.recorder" and certificate leaf = H"00112233445566778899aabbccddeeff00112233""#
        // Oatcake signed the same way, and new enough to be signed for the hardened runtime.
        #expect(RecorderGate.caller(forRecorder: release) == .mustMeet(#"identifier "local.oatcake" and info [CFBundleShortVersionString] >= "0.5.0" and certificate leaf = H"00112233445566778899aabbccddeeff00112233""#))
        // A certificate from Apple names its team instead of a fingerprint: the same rule holds.
        #expect(RecorderGate.caller(forRecorder: #"identifier "local.oatcake.recorder" and anchor apple generic and certificate leaf[subject.OU] = ABCDE12345"#)
            == .mustMeet(#"identifier "local.oatcake" and info [CFBundleShortVersionString] >= "0.5.0" and anchor apple generic and certificate leaf[subject.OU] = ABCDE12345"#))
        // The recorder's own requirement names the version too (Scripts/bundle.sh): Oatcake is held to all of it.
        #expect(RecorderGate.caller(forRecorder: #"identifier "local.oatcake.recorder" and certificate leaf = H"00112233445566778899aabbccddeeff00112233" and info[CFBundleShortVersionString] >= "0.5.0""#)
            == .mustMeet(#"identifier "local.oatcake" and info [CFBundleShortVersionString] >= "0.5.0" and certificate leaf = H"00112233445566778899aabbccddeeff00112233" and info[CFBundleShortVersionString] >= "0.5.0""#))
        // A development build is signed ad-hoc: there's no certificate to hold the caller to.
        #expect(RecorderGate.caller(forRecorder: #"cdhash H"00112233445566778899aabbccddeeff00112233""#) == .anyone)
        // Anything else is nobody: a signature that can't be read, or somebody else's program.
        #expect(RecorderGate.caller(forRecorder: "") == .nobody)
        #expect(RecorderGate.caller(forRecorder: #"identifier "com.example.other" and certificate leaf = H"00""#) == .nobody)
        #expect(RecorderGate.caller(forRecorder: #"anchor apple and identifier "local.oatcake.recorder""#) == .nobody)
    }

    /// What a recorder does: connects, asks about a folder, reads the answer.
    private func ask(_ socketPath: String, about dir: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return "no connection" }
        let question = Array((dir + "\n").utf8)
        _ = question.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = [UInt8](repeating: 0, count: 16)
        let got = read(fd, &reply, reply.count)
        return got > 0 ? String(decoding: reply[..<got], as: UTF8.self).trimmed : "no reply"
    }

    @Test func onlyRecordingsOatcakeStarted() throws {
        // /tmp rather than the test's own temporary folder: a socket's path has to be short.
        let folder = URL(fileURLWithPath: "/tmp/oatcake-door-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let door = RecorderDoor(directory: folder)
        let mine = folder.appendingPathComponent("2026-11-14T10-00-00-000Z")
        let socket = try door.expect(mine)
        #expect(ask(socket, about: "/tmp/somewhere-else") == RecorderGate.no)
        #expect(ask(socket, about: mine.path) == RecorderGate.yes)
        // Once: a second recorder asking about the same recording is turned away.
        #expect(ask(socket, about: mine.path) == RecorderGate.no)
        // A recorder that never started isn't waited for.
        let other = folder.appendingPathComponent("2026-11-14T11-00-00-000Z")
        #expect(try door.expect(other) == socket)
        door.forget(other)
        #expect(ask(socket, about: other.path) == RecorderGate.no)
    }

    @Test func filesBothProgramsRead() throws {
        // mic.json says "the Mac's input" with a null, not by leaving the key out.
        #expect(String(decoding: try JSONEncoder().encode(MicRequest(uid: nil)), as: UTF8.self) == #"{"uid":null}"#)
        #expect(try JSONDecoder().decode(MicRequest.self, from: Data(#"{"uid":"BuiltInMic"}"#.utf8)).uid == "BuiltInMic")
        // A status as the recorder writes it, and a meta.json from before the two shared these types (it had micDevices too).
        let status = try JSONDecoder().decode(RecorderStatus.self, from: JSONEncoder().encode(RecorderStatus(state: .recording, elapsed: 12, micLevel: 0.2, systemLevel: 0, micDevice: MicChoice(uid: "a", name: "A"))))
        #expect(status.state == .recording && status.micDevice?.name == "A")
        let older = #"{"endedAt":"2026-11-05T15:00:00Z","micDevices":[{"at":0,"name":"A","uid":"a"}],"micOffset":0.4,"sampleRate":16000,"startedAt":"2026-11-05T14:00:00Z","systemOffset":0.1}"#
        #expect(try JSONDecoder().decode(RecorderMeta.self, from: Data(older.utf8)).micOffset == 0.4)
        // A status from a recorder before it gave the tracks' offsets reads as not having them yet.
        let earlier = try JSONDecoder().decode(RecorderStatus.self, from: Data(#"{"state":"recording","elapsed":3}"#.utf8))
        #expect(earlier.micOffset == nil && earlier.systemOffset == nil)
    }
}

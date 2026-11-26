// Records a meeting as two tracks: the microphone (you) and everything the Mac
// plays (everyone else), captured with a Core Audio process tap.
//
// Usage: oatcake-recorder --out <dir> --ask <socket>   record until SIGINT or SIGTERM
//        oatcake-recorder --list-inputs               print the input devices as JSON
// Writes 16 kHz mono PCM16 to <dir>/mic.pcm and <dir>/system.pcm, status.json
// once a second, and meta.json on stop. Reads <dir>/mic.json every second for the
// chosen input, so it can be changed mid-call. The files' names and shapes are
// RecorderContract's, which Oatcake reads them with.
//
// It records only for Oatcake: before anything is captured it asks, on the socket it
// was given, whether Oatcake wants this recording, having checked by code signature
// that it is Oatcake at the other end (RecorderGate). It stops by itself when its
// folder is deleted, when the disk is almost full or can't take any more, and when
// Oatcake has been gone for ten minutes (RecorderWatch decides).
//
// The system-audio tap is adapted from OpenWhispr's macos-audio-tap.swift
// (MIT, Copyright (c) 2024 OpenWhispr Team). See THIRD_PARTY_NOTICES.md.

import AVFoundation
import CoreAudio
import Foundation
import RecorderContract
import Security

let sampleRate = Double(recorderSampleRate)
let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

/// A track's file.
final class TrackFile: TrackOutput {
    private let handle: FileHandle

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() { try? handle.close() }
}

/// Converts incoming buffers to 16 kHz mono PCM16 for its writer, which keeps the track lined up
/// (RecorderContract's TrackWriter).
final class Track {
    let writer: TrackWriter
    private var converter: AVAudioConverter?

    init(path: String) throws {
        writer = TrackWriter(output: try TrackFile(path: path))
    }

    func append(_ source: AVAudioPCMBuffer) {
        if converter == nil || converter!.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
            converter?.downmix = true  // multi-mic arrays: mix every channel into the mono track
        }
        guard let converter else { return }

        let capacity = AVAudioFrameCount(
            ceil(Double(source.frameLength) * sampleRate / max(source.format.sampleRate, 1))) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, status == .haveData || status == .inputRanDry,
              let samples = output.int16ChannelData?[0] else { return }
        writer.append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}

/// Everything the Mac plays, via a global process tap on an aggregate device.
/// Checked once a second, as the microphone is: it's started again when its audio stops arriving
/// (the Mac slept with its lid closed, say) or its format changes (headphones connected), with the
/// time that took filled with silence, so the call stays lined up with your track.
final class SystemAudioCapture {
    private let track: Track
    private var tapID = AudioObjectID(0)
    private var deviceID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var startedAt = Date.distantPast
    private let queue = DispatchQueue(label: "oatcake-recorder.system")

    init(track: Track) { self.track = track }

    func check() {
        let changed = procID != nil && tapFormat() != format
        guard CaptureCheck.needsRestart(running: procID != nil, changed: changed, startedAt: startedAt,
                                        lastBuffer: track.writer.lastBufferAt, now: Date()) else { return }
        stop()
        track.writer.markGap()
        do {
            try start()
        } catch {
            stop()  // the next check tries again
        }
    }

    /// The format the tap delivers in now; nil if it can't be read.
    private func tapFormat() -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard tapID != 0, AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    func start() throws {
        let description = CATapDescription()
        description.name = "oatcake-recorder"
        description.uuid = UUID()
        description.processes = []  // exclusive + empty = every process
        description.isExclusive = true
        description.isMono = true
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try OatcakeRecorder.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try OatcakeRecorder.check(withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }, "read tap UID")
        guard let tapUID = uid?.takeRetainedValue() as String? else { throw RecorderError("tap has no UID") }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "oatcake-recorder",
            kAudioAggregateDeviceUIDKey: "oatcake-recorder.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        try OatcakeRecorder.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create aggregate device")

        guard let format = tapFormat() else { throw RecorderError("couldn’t read the tap’s format") }

        let track = self.track
        try OatcakeRecorder.check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: UnsafeMutablePointer(mutating: input), deallocator: nil)
            else { return }
            track.append(buffer)
        }, "create IO proc")

        try OatcakeRecorder.check(AudioDeviceStart(deviceID, procID), "start aggregate device")
        self.format = format
        startedAt = Date()
    }

    func stop() {
        if deviceID != 0 { AudioDeviceStop(deviceID, procID) }
        if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
        if deviceID != 0 { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = 0
        tapID = 0
        format = nil
    }
}

// MARK: - Input devices

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var where_ = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &where_, 0, nil, &size, $0) }
    guard status == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

/// Every device with an input stream, in the order macOS lists them.
func inputDevices() -> [InputDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &devices, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &devices, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("oatcake-recorder"),
              let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return InputDevice(id: id, uid: uid, name: name)
    }
}

func defaultInputDevice() -> AudioDeviceID {
    var where_ = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &id)
    return id
}

/// The format the device delivers its first input stream in, or nil if it has none right now.
func inputFormat(_ id: AudioDeviceID) -> AVAudioFormat? {
    var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }
    var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &streams, 0, nil, &size, &ids) == noErr, let stream = ids.first else { return nil }
    var virtual = address(kAudioStreamPropertyVirtualFormat)
    var asbd = AudioStreamBasicDescription()
    size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &virtual, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
    // AVAudioFormat needs a layout for more than two channels; they're mixed down to mono later.
    let layout = asbd.mChannelsPerFrame > 2
        ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
        : nil
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
}

/// The chosen input, or the Mac's current input when none is chosen or the chosen one is
/// unplugged. check() runs every second and restarts capture whenever the device it should be
/// on changes, its format changes, or audio stops arriving, so the recording carries on through
/// headphones connecting, a mic being unplugged, or a change of input in System Settings.
///
/// Reads the device directly through Core Audio rather than AVAudioEngine: AVAudioEngine throws
/// Objective-C exceptions (which Swift can't catch) when a device changes format mid-setup, and
/// one of those crashed a recording on 2026-11-05 as Bluetooth headphones switched modes.
final class MicCapture {
    private let track: Track
    private let queue = DispatchQueue(label: "oatcake-recorder.mic")
    private var deviceID = AudioDeviceID(0)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var startedAt = Date.distantPast
    /// Device UID from mic.json; nil follows the Mac's input.
    var wanted: String?
    private(set) var device: InputDevice?

    init(track: Track) { self.track = track }

    func check() {
        let devices = inputDevices()
        let fallback = defaultInputDevice()
        let target = devices.first { $0.uid == wanted } ?? devices.first { $0.id == fallback }
        let changed = procID != nil && (inputFormat(deviceID) != format || target?.uid != device?.uid)
        if CaptureCheck.needsRestart(running: procID != nil, changed: changed, startedAt: startedAt,
                                     lastBuffer: track.writer.lastBufferAt, now: Date()) {
            restart(on: target)
        }
    }

    private func restart(on target: InputDevice?) {
        stop()
        guard let target, let format = inputFormat(target.id) else { return }  // the next check tries again
        let track = self.track
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, target.id, queue) { _, input, _, _, _ in
            // One buffer per input stream; record the first.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mDataByteSize > 0 else { return }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &list, deallocator: nil) else { return }
            track.append(buffer)
        }
        guard created == noErr, let proc else { return }
        track.writer.markGap()
        guard AudioDeviceStart(target.id, proc) == noErr else {
            AudioDeviceDestroyIOProcID(target.id, proc)
            return
        }
        deviceID = target.id
        procID = proc
        self.format = format
        device = target
        startedAt = Date()
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = 0
        format = nil
        device = nil
    }
}

struct RecorderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw RecorderError("\(what) failed (OSStatus \(status))") }
}

private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

func writeJSON<T: Encodable>(_ value: T, to path: String) {
    guard let data = try? jsonEncoder.encode(value) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// MARK: - Who's asking

/// This program's own designated requirement, as text: who signed it.
func ownRequirement() -> String? {
    var me: SecCode?
    var staticCode: SecStaticCode?
    var requirement: SecRequirement?
    var text: CFString?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
          SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
          SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
    return text as String
}

/**
 * Asks whoever is listening on `socketPath` whether a recording into `dir` is wanted, and believes
 * the answer only if that program's code signature meets `requirement` (it is Oatcake, signed with
 * this recorder's certificate). The check is on the process at the other end of the connection, as
 * the system identifies it, so it can't be faked by what's sent or by reusing a process ID.
 */
func oatcakeWants(_ dir: String, askingAt socketPath: String, requirement: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    let room = MemoryLayout.size(ofValue: address.sun_path)
    guard path.count < room else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return false }

    // Who is it? The system's own token for the process holding the other end.
    var token = audit_token_t()
    var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else { return false }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var peer: SecCode?
    var wanted: SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &peer) == errSecSuccess, let peer,
          SecRequirementCreateWithString(requirement as CFString, [], &wanted) == errSecSuccess, let wanted,
          SecCodeCheckValidity(peer, [], wanted) == errSecSuccess else { return false }
    // And it has to be signed for the hardened runtime: a copy that isn't can have another program's
    // code loaded into it, and then it isn't only Oatcake that's answering.
    var peerOnDisk: SecStaticCode?
    var signing: CFDictionary?
    guard SecCodeCopyStaticCode(peer, [], &peerOnDisk) == errSecSuccess, let peerOnDisk,
          SecCodeCopySigningInformation(peerOnDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
          let flags = (signing as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32,
          flags & SecCodeSignatureFlags.runtime.rawValue != 0 else { return false }

    let question = Array((dir + "\n").utf8)
    guard question.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == question.count else { return false }
    var reply = [UInt8](repeating: 0, count: 16)
    let got = read(fd, &reply, reply.count)
    guard got > 0 else { return false }
    return String(decoding: reply[..<got], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == RecorderGate.yes
}

func requestMicAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        let done = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
        done.wait()
        // Asked again rather than carried across from the answer's own thread.
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    default: return false
    }
}

// MARK: - Main

let args = CommandLine.arguments
if args.contains("--list-inputs") {
    let current = defaultInputDevice()
    let list = inputDevices().map { ["uid": $0.uid, "name": $0.name, "isDefault": $0.id == current] as [String: Any] }
    let data = try! JSONSerialization.data(withJSONObject: list)
    FileHandle.standardOutput.write(data)
    exit(0)
}
guard let outFlag = args.firstIndex(of: "--out"), outFlag + 1 < args.count else {
    FileHandle.standardError.write("usage: oatcake-recorder --out <dir> --ask <socket> | --list-inputs\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[outFlag + 1]
let statusPath = "\(outDir)/\(RecorderFile.status)"

/// Whether the recording's folder is still there. Oatcake makes it; if it has gone (the recording
/// was cancelled or discarded) there's nothing to record into, and it isn't made again.
func folderExists() -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: outDir, isDirectory: &isDirectory) && isDirectory.boolValue
}
guard folderExists() else { exit(2) }

/// Whether another recorder is already at work in this folder. Then the folder is that recording's,
/// and this one leaves without touching anything in it.
func anotherRecorderIsHere() -> Bool {
    guard let text = try? String(contentsOfFile: "\(outDir)/\(RecorderFile.pid)", encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, pid != getpid() else { return false }
    // By its program, as Oatcake checks: a process ID left in the file can belong to something else by now.
    return isRunning(pid, program: ProgramName.recorder)
}
guard !anotherRecorderIsHere() else { exit(1) }
// A recording that's already over (stopped before this recorder got going) isn't started again.
guard !FileManager.default.fileExists(atPath: "\(outDir)/\(RecorderFile.meta)") else { exit(0) }

func fail(_ message: String) -> Never {
    if folderExists() { writeJSON(RecorderStatus(state: .error, error: message), to: statusPath) }
    try? FileManager.default.removeItem(atPath: "\(outDir)/\(RecorderFile.pid)")
    exit(1)
}

// Nothing is captured, and no permission is asked for, until it's known that Oatcake wants this.
switch RecorderGate.caller(forRecorder: ownRequirement() ?? "") {
case .anyone:
    break
case .nobody:
    fail("The recorder couldn’t check that Oatcake started it, so nothing was recorded. Install Oatcake again.")
case .mustMeet(let requirement):
    let askFlag = args.firstIndex(of: RecorderGate.argument)
    guard let askFlag, askFlag + 1 < args.count, oatcakeWants(outDir, askingAt: args[askFlag + 1], requirement: requirement) else {
        fail("The recorder only records when Oatcake asks it to, and it couldn’t confirm that Oatcake did.")
    }
}
try? "\(getpid())".write(toFile: "\(outDir)/\(RecorderFile.pid)", atomically: true, encoding: .utf8)

let startedAt = Date()
let micTrack: Track
let systemTrack: Track
do {
    micTrack = try Track(path: "\(outDir)/\(RecorderFile.micTrack)")
    systemTrack = try Track(path: "\(outDir)/\(RecorderFile.systemTrack)")
} catch {
    fail("cannot create audio files in \(outDir): \(error)")
}

guard requestMicAccess() else {
    fail("Microphone access is off. Turn on Oatcake in System Settings › Privacy & Security › Microphone.")
}

/// The app writes {"uid": "<device UID>"} to mic.json to choose an input (null = the Mac's).
func wantedMic() -> String? {
    guard let data = FileManager.default.contents(atPath: "\(outDir)/\(RecorderFile.mic)") else { return nil }
    return (try? JSONDecoder().decode(MicRequest.self, from: data))?.uid
}

/// Whether the Oatcake that owns this recording is still running. True when there's no saying.
func ownerIsRunning() -> Bool {
    guard let text = try? String(contentsOfFile: "\(outDir)/\(RecorderFile.owner)", encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return true }
    // A process ID given out again to another program isn't Oatcake still running.
    return isRunning(pid, program: ProgramName.app)
}

/// Bytes free on the recording's disk.
/// Counts the purgeable space (snapshots, caches, iCloud files kept online) that macOS frees for a
/// write you asked for, so a disk that only looks full doesn't stop the call.
func freeSpace() -> Int64? {
    (try? URL(fileURLWithPath: outDir).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
}

let system = SystemAudioCapture(track: systemTrack)
let mic = MicCapture(track: micTrack)
do {
    try system.start()
} catch {
    fail("\(error)")
}
mic.wanted = wantedMic()
mic.check()

/// Seconds from the start to a track's first sample, once it has one.
@MainActor func offset(_ track: Track) -> Double? {
    track.writer.firstBufferAt.map { $0.timeIntervalSince(startedAt) }
}

let iso = ISO8601DateFormatter()
var watch = RecorderWatch()
let statusTimer = DispatchSource.makeTimerSource(queue: .main)
statusTimer.schedule(deadline: .now() + 1, repeating: 1)
// The timer and the signals below are all handled on the main queue, which is where this program's state lives.
statusTimer.setEventHandler { MainActor.assumeIsolated {
    // Oatcake quitting stops the recorder itself; the ten minutes are for an Oatcake that crashed and wasn't opened again.
    let seen = RecorderSurroundings(folderExists: folderExists(), writeFailure: micTrack.writer.failure ?? systemTrack.writer.failure,
                                    ownerIsRunning: ownerIsRunning(), freeSpace: freeSpace())
    switch watch.look(at: seen) {
    case .carryOn:
        break
    case .abandon:
        // The recording was cancelled or discarded: there's nothing left to record into.
        mic.stop()
        system.stop()
        exit(0)
    case .finish(.cantWrite(let failure)):
        finish(because: "The recording stopped because it couldn’t be written to disk any more (\(failure)). What was recorded up to then is kept.")
    case .finish(.diskAlmostFull):
        finish(because: "The recording stopped because the disk is almost full. What was recorded up to then is kept.")
    case .finish(.oatcakeGone):
        finish(because: "Oatcake wasn’t running, so the recording stopped by itself after ten minutes.")
    }
    mic.wanted = wantedMic()
    mic.check()
    system.check()
    // The offsets go in every status too, so a recorder that's killed or crashes still leaves them.
    writeJSON(RecorderStatus(state: .recording, elapsed: Date().timeIntervalSince(startedAt),
                             micLevel: Double(micTrack.writer.takePeak()), systemLevel: Double(systemTrack.writer.takePeak()),
                             micDevice: mic.device.map { MicChoice(uid: $0.uid, name: $0.name) },
                             micOffset: offset(micTrack), systemOffset: offset(systemTrack)), to: statusPath)
} }
statusTimer.resume()

/// Finishes the recording: meta.json, then a last status. `because` is why it stopped when it
/// wasn't asked to; Oatcake shows it. meta.json is written before the devices are stopped, which
/// can hang: Oatcake stops a recorder that's still there five seconds after it was asked to finish,
/// and the offsets would go with it.
@MainActor func finish(because reason: String? = nil) -> Never {
    statusTimer.cancel()
    micTrack.writer.close()
    systemTrack.writer.close()
    writeJSON(RecorderMeta(startedAt: iso.string(from: startedAt), endedAt: iso.string(from: Date()),
                           micOffset: offset(micTrack) ?? 0, systemOffset: offset(systemTrack) ?? 0),
              to: "\(outDir)/\(RecorderFile.meta)")
    mic.stop()
    system.stop()
    writeJSON(reason.map { RecorderStatus(state: .error, error: $0) } ?? RecorderStatus(state: .stopped), to: statusPath)
    try? FileManager.default.removeItem(atPath: "\(outDir)/\(RecorderFile.pid)")
    exit(reason == nil ? 0 : 1)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    // The closure's type is spelled out: finish() never returns, and the compiler in Xcode 26 can't
    // work out what a closure made only of that call should return.
    source.setEventHandler { MainActor.assumeIsolated { () -> Void in finish() } }
    source.resume()
    signalSources.append(source)
}

// A run loop on the main thread, rather than dispatchMain(): everything above that's handled on the
// main queue then really is on the main thread, which is what it says it is.
while true { RunLoop.main.run(mode: .default, before: .distantFuture) }

import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct UpdateTests {
    /// Signed by the Release workflow's Node script; checked here with CryptoKit.
    @Test func readsTheRealManifest() throws {
        let m = try Update.readManifest(Data(contentsOf: fixture("latest-0.3.0.json")))
        #expect(m.version == "0.3.0")
        #expect(m.bundleID == "local.oatcake")
        #expect(m.zip.name == "Oatcake-v0.3.0-arm64.zip")
    }

    @Test func refusesATamperedManifest() throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("latest-0.3.0.json"))) as! [String: String]
        var payload = String(decoding: Data(base64Encoded: json["payload"]!)!, as: UTF8.self)
        payload = payload.replacingOccurrences(of: "0.3.0", with: "9.9.9")
        json["payload"] = Data(payload.utf8).base64EncodedString()
        #expect(throws: OatcakeError("The update information isn't signed with Oatcake's release key.")) {
            try Update.readManifest(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func versions() {
        #expect(Update.compareVersions("0.10.0", "0.9.9") == 1)
        #expect(Update.compareVersions("1.0", "1.0.0") == 0)
        #expect(Update.compareVersions("0.3.0", "0.4.0") == -1)
    }

    /// The update information is signed, and then every field has to be what it should be. The key
    /// here is made for the test; the manifest is in the shape the Release workflow writes.
    @Test func checksEveryField() throws {
        let key = Curve25519.Signing.PrivateKey()
        let keys = [key.publicKey.rawRepresentation.base64EncodedString()]
        func envelope(_ change: (inout Update.Manifest) -> Void = { _ in }, signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
            var manifest = Update.Manifest(bundleID: "local.oatcake", version: "0.5.0", minimumSystemVersion: "15.0", published: "2026-11-14T10:00:00Z", notes: "- A change",
                                           zip: .init(name: "Oatcake-v0.5.0-arm64.zip", url: "https://example.com/Oatcake-v0.5.0-arm64.zip", sha256: String(repeating: "ab", count: 32), size: 1_000))
            change(&manifest)
            let payload = try JSONEncoder().encode(manifest)
            let signature = try (signer ?? key).signature(for: payload)
            return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()])
        }
        #expect(try Update.readManifest(envelope(), keys: keys).version == "0.5.0")
        // Signed, but by a key Oatcake doesn't ship: refused before anything in it is looked at.
        #expect(throws: OatcakeError("The update information isn't signed with Oatcake's release key.")) {
            try Update.readManifest(envelope(signedBy: Curve25519.Signing.PrivateKey()), keys: keys)
        }
        #expect(throws: OatcakeError("The update information isn't in the expected format.")) { try Update.readManifest(Data("{}".utf8), keys: keys) }
        let incomplete = OatcakeError("The update information is incomplete.")
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.bundleID = "local.other" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.version = "0.5" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.version = "0.5.0; rm" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.minimumSystemVersion = "fifteen" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.zip.name = "../Oatcake.zip" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.zip.name = "Oatcake.dmg" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.zip.url = "http://example.com/Oatcake.zip" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.zip.sha256 = "abc" }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.zip.sha256 = String(repeating: "AB", count: 32) }, keys: keys) }
        #expect(throws: incomplete) { try Update.readManifest(envelope { $0.zip.size = 0 }, keys: keys) }
    }

    /// The release's zip is read as it arrives, in pieces, and kept only when it's the size and
    /// checksum the release gave.
    @Test func downloadsTheZip() async throws {
        let zip = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 11) })
        let server = try await StandIn { request in request.path == "/gone.zip" ? StandIn.Response(status: 404) : StandIn.Response(body: zip) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func manifest(name: String = "Oatcake-v0.5.0-arm64.zip", at address: String? = nil, size: Int = zip.count,
                      sha256: String = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()) -> Update.Manifest {
            Update.Manifest(bundleID: "local.oatcake", version: "0.5.0", minimumSystemVersion: "15.0", published: "2026-11-14T10:00:00Z", notes: "- A change",
                            zip: .init(name: name, url: (address ?? server.address) + "/" + name, sha256: sha256, size: size))
        }
        let told = Locked([Double]())
        let file = try await Update.downloadZip(manifest(), into: dir) { told.value.append($0) }
        #expect(try Data(contentsOf: file) == zip)
        #expect(told.value.count >= 2 && told.value.count <= 4 && told.value.last == 1)

        await #expect(throws: OatcakeError("The download is bigger than the release said it would be.")) {
            _ = try await Update.downloadZip(manifest(size: zip.count - 1), into: dir) { _ in }
        }
        await #expect(throws: OatcakeError("The download stopped early (\(zip.count) of \(zip.count + 1) bytes).")) {
            _ = try await Update.downloadZip(manifest(size: zip.count + 1), into: dir) { _ in }
        }
        await #expect(throws: OatcakeError("The download doesn't match the release's checksum.")) {
            _ = try await Update.downloadZip(manifest(sha256: String(repeating: "ab", count: 32)), into: dir) { _ in }
        }
        await #expect(throws: OatcakeError("The download failed (HTTP 404).")) {
            _ = try await Update.downloadZip(manifest(name: "gone.zip"), into: dir) { _ in }
        }
        await #expect(throws: OatcakeError("Couldn't download the update. Check your connection and try again.")) {
            _ = try await Update.downloadZip(manifest(at: "http://127.0.0.1:9"), into: dir) { _ in }
        }
    }

    /// A swap that can't be started leaves no staged copy beside the app.
    @Test func aSwapThatCantStartLeavesNothingBehind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-swap-\(UUID().uuidString)")
        let staged = dir.appendingPathComponent(".Oatcake-update.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A file stands where the log's folder would be, so the swap fails before anything is started.
        let blocker = dir.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        #expect(throws: (any Error).self) {
            try Update.swapAfterExit(installed: dir.appendingPathComponent("Oatcake.app"), staged: staged, log: blocker.appendingPathComponent("update.log"))
        }
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}

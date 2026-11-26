import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Security
import Testing

@Suite struct SecretsTests {
    /// Chromium's OSCrypt, as Electron's safeStorage wrote secrets.json.
    @Test func decryptsElectronSecrets() throws {
        // Made with: openssl enc -aes-128-cbc -K <PBKDF2-SHA1("pw","saltysalt",1003,16)> -iv 2020…20
        let cipher = try #require(Data(base64Encoded: "djEw/mXxrkPO2PfVblTVrGD1Ug=="))
        #expect(Secrets.decryptOSCrypt(cipher, password: "pw") == "secret")
        #expect(Secrets.decryptOSCrypt(Data("plain".utf8), password: "pw") == nil)
    }

    private func secretFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oatcake-secrets-\(UUID().uuidString)/private.json")
    }

    /// The calendar's address is kept in a file only you can read, and a blank one removes it.
    @Test func keepsTheAddressInAPrivateFile() throws {
        let file = secretFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Secrets.set(.calendar, "  https://calendar.example.com/private.ics \n", file: file)
        #expect(Secrets.savedValue(.calendar, file) == "https://calendar.example.com/private.ics")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        try Secrets.set(.calendar, " ", file: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(Secrets.savedValue(.calendar, file) == nil)
    }

    /// 0.4.0 to 0.5.2 kept it in the Keychain: it moves into the file, and the Keychain item goes.
    @Test func movesTheAddressOutOfTheKeychain() throws {
        let file = secretFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var deleted: [String] = []
        #expect(Secrets.moveFromKeychain(file: file, read: { _ in (errSecSuccess, "https://a.example.com/a.ics") }, delete: { deleted.append($0) }))
        #expect(Secrets.savedValue(.calendar, file) == "https://a.example.com/a.ics")
        #expect(deleted == ["calendar"])

        // One already in the file stays, and the Keychain isn't read for it (reading is what asks
        // for your login password); its item is still deleted.
        try Secrets.set(.calendar, "https://b.example.com/b.ics", file: file)
        deleted = []
        #expect(Secrets.moveFromKeychain(file: file, read: { _ in
            Issue.record("The Keychain was read")
            return (errSecSuccess, "https://a.example.com/a.ics")
        }, delete: { deleted.append($0) }))
        #expect(Secrets.savedValue(.calendar, file) == "https://b.example.com/b.ics")
        #expect(deleted == ["calendar"])
    }

    /// Nothing in the Keychain: done. Refused (Deny): not done, so it's asked again at the next
    /// launch, and nothing is written or deleted.
    @Test func keychainMoveWaitsWhenRefused() {
        let file = secretFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(Secrets.moveFromKeychain(file: file, read: { _ in (errSecItemNotFound, nil) }, delete: { _ in Issue.record("Deleted") }))
        #expect(!Secrets.moveFromKeychain(file: file, read: { _ in (errSecAuthFailed, nil) }, delete: { _ in Issue.record("Deleted") }))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

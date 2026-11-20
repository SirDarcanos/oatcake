// The calendar's private address, typed into Settings, kept in private.json in Oatcake's own data
// folder, which only you can read. The window can save it and learn whether it's saved, but never
// reads it back. (It's the only secret left: the language model runs on this Mac and needs no key.)
//
// It isn't in the Keychain any more. A Keychain item remembers the exact build that made it, and
// every release of a self-signed app is a new build to macOS, so each update asked for your login
// password before Oatcake could read the address again.

import CommonCrypto
import Foundation
import Security

public enum SecretName: String, CaseIterable, Sendable {
    case calendar

    /// One already in the environment when Oatcake started (e.g. from your shell) is the fallback.
    var environmentVariable: String {
        switch self {
        case .calendar: "OATCAKE_CALENDAR_URL"
        }
    }
}

public enum Secrets {
    static let service = "Oatcake"

    /// The saved value, or the one inherited from the environment, or "".
    public static func get(_ name: SecretName, file: URL = Paths.secretFile) -> String {
        if let saved = savedValue(name, file), !saved.isEmpty { return saved }
        return ProcessInfo.processInfo.environment[name.environmentVariable] ?? ""
    }

    /// What Settings shows: whether one is saved, and enough to recognise it.
    public static func describe(_ name: SecretName, file: URL = Paths.secretFile) -> (saved: Bool, hint: String) {
        guard let value = savedValue(name, file), !value.isEmpty else {
            let inherited = ProcessInfo.processInfo.environment[name.environmentVariable]
            return (false, inherited != nil ? "Using the address from your shell" : "")
        }
        let host = URL(string: value.replacingOccurrences(of: "webcal:", with: "https:", options: [.anchored, .caseInsensitive]))?.host
        return (true, host.map { "Saved · \($0)" } ?? "Saved")
    }

    /// Saves a secret, or removes it when the value is blank. The file is written afresh, readable
    /// only by you, and then put in place of the old one: a save that fails keeps the old value.
    public static func set(_ name: SecretName, _ value: String, file: URL = Paths.secretFile) throws {
        var all = tryJSON([String: String].self, file) ?? [:]
        let clean = value.trimmed
        all[name.rawValue] = clean.isEmpty ? nil : clean
        if all.isEmpty {
            if FileManager.default.exists(file) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(file, try encodeJSON(all) + "\n", permissions: 0o600)
    }

    static func savedValue(_ name: SecretName, _ file: URL) -> String? {
        tryJSON([String: String].self, file)?[name.rawValue]
    }

    // MARK: - From the Keychain (0.4.0 to 0.5.2)

    /**
     * Versions 0.4.0 to 0.5.2 kept the secrets in the login Keychain. They move into the file, which
     * asks for your login password one last time, and the Keychain item is deleted (if macOS lets
     * this build delete it: one left behind is never read again). Run once, at launch.
     *
     * Returns whether that's done: false when the Keychain wouldn't give one up (you chose Deny), so
     * it's tried again at the next launch. Saving an address in Settings meanwhile settles it.
     */
    public static func moveFromKeychain() -> Bool {
        moveFromKeychain(file: Paths.secretFile, read: { keychainLookup(account: $0) }, delete: { keychainDelete(account: $0) })
    }

    static func moveFromKeychain(file: URL, read: (String) -> (status: OSStatus, value: String?), delete: (String) -> Void) -> Bool {
        var done = true
        for name in SecretName.allCases {
            // One already in the file wins, and the Keychain isn't read for it: reading is what asks.
            if savedValue(name, file) == nil {
                let found = read(name.rawValue)
                if found.status == errSecItemNotFound { continue }
                guard found.status == errSecSuccess, let value = found.value else {
                    done = false
                    continue
                }
                do { try set(name, value, file: file) } catch {
                    done = false
                    continue
                }
            }
            delete(name.rawValue)
        }
        return done
    }

    static func keychainLookup(account: String, service: String = service) -> (status: OSStatus, value: String?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        return (status, (result as? Data).flatMap { String(data: $0, encoding: .utf8) })
    }

    static func keychainRead(account: String, service: String = service) -> String? {
        let found = keychainLookup(account: account, service: service)
        return found.status == errSecSuccess ? found.value : nil
    }

    static func keychainDelete(account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }

    // MARK: - No longer kept

    /// Secrets Oatcake once kept and has no use for now: the keys for the Anthropic API and for an
    /// OpenAI-compatible service, from when summaries could be written by a model somewhere else.
    static let retired = ["anthropic", "openai"]

    /// Removes them from the Keychain. Done at launch; there's nothing to remove after the first time.
    public static func forgetRetired() {
        for account in retired { keychainDelete(account: account) }
    }

    // MARK: - From the Electron version

    /// The Electron version kept secrets in secrets.json, encrypted with Chromium's OSCrypt under a
    /// key in the Keychain ("Oatcake Safe Storage"). They move into private.json once, and the file
    /// goes. A secret that can't be read, or can't be saved, is left in the file for the next launch.
    public static func migrateFromElectron(_ file: URL = Paths.data.appendingPathComponent("secrets.json")) {
        guard let stored = tryJSON([String: String].self, file), !stored.isEmpty else { return }
        guard let password = keychainRead(account: "Oatcake Key", service: "Oatcake Safe Storage") else { return }
        var remaining = stored
        for (key, value) in stored {
            // One that's no longer kept is dropped rather than moved.
            if retired.contains(key) {
                remaining.removeValue(forKey: key)
                continue
            }
            guard let name = SecretName(rawValue: key), let data = Data(base64Encoded: value),
                  let plain = decryptOSCrypt(data, password: password) else { continue }
            if savedValue(name, Paths.secretFile) == nil {
                do { try set(name, plain) } catch { continue }
            }
            remaining.removeValue(forKey: key)
        }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let text = try? encodeJSON(remaining) {
            try? writeAtomic(file, text, permissions: 0o600)
        }
    }

    /// Chromium's macOS scheme: "v10" + AES-128-CBC (IV of 16 spaces) under PBKDF2-SHA1(password, "saltysalt", 1003).
    static func decryptOSCrypt(_ data: Data, password: String) -> String? {
        guard data.starts(with: Data("v10".utf8)) else { return nil }
        let body = data.dropFirst(3)
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = password.withCString { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, strlen(pw), salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + 16)
        var moved = 0
        let status = body.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, input.baseAddress, body.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: out[..<moved], encoding: .utf8)
    }
}

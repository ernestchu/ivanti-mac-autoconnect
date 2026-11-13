// Credentials: one keychain item holding the sign-in address, password and TOTP secret,
// plus the TOTP code generator (RFC 6238: HMAC-SHA1, 30 s, 6 digits).
import Foundation
import Security
import CryptoKit

struct Credentials: Codable {
    var user: String
    var password: String
    var totpSecret: String   // normalized base32, no spaces
}

enum CredentialStore {
    // A single item, so there is only ever one set of credentials. Saving replaces it.
    private static let service = "Ivanti AutoConnect credentials"
    private static let oldService = "IvantiVPN credentials"   // name before the app was renamed
    private static let account = "default"

    private static func query(_ svc: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: svc,
         kSecAttrAccount as String: account]
    }
    private static var baseQuery: [String: Any] { query() }

    /// Moves credentials saved under the app's old name (IvantiVPN) to the current name, so
    /// renaming the app doesn't mean setting up again. Call once at launch.
    static func migrateOldName() {
        var q = query(oldService)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let c = try? JSONDecoder().decode(Credentials.self, from: data) else { return }
        if !exists() { try? save(c) }
        // macOS only lets the app that created an item delete it, and the renamed app doesn't
        // count, so this may fail (errSecInvalidOwnerEdit); the old item then just stays unused.
        if exists() { SecItemDelete(query(oldService) as CFDictionary) }
    }

    /// Whether credentials are saved. Reads only the item's attributes, so it never prompts.
    static func exists() -> Bool {
        var q = baseQuery
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> Credentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ c: Credentials) throws {
        // Replace the current item only. The old-name item is deleted by migrateOldName() once
        // this copy exists, so a failed save never loses the only copy.
        SecItemDelete(baseQuery as CFDictionary)
        removeLegacy()
        var q = baseQuery
        q[kSecValueData as String] = try JSONEncoder().encode(c)
        q[kSecAttrLabel as String] = service
        q[kSecAttrDescription as String] = "Ivanti VPN sign-in (address, password, authenticator secret)"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"])
        }
    }

    static func remove() {
        SecItemDelete(baseQuery as CFDictionary)
        SecItemDelete(query(oldService) as CFDictionary)
        removeLegacy()
    }

    /// Items written by the old command-line version (ivanti-vpn.sh setup), so no stale copy of
    /// a password or secret is left behind. They trust /usr/bin/security, so deleting through it
    /// doesn't prompt.
    private static func removeLegacy() {
        for k in ["user", "pass", "totp"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["delete-generic-password", "-s", "ivanti-vpn-\(k)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}

enum TOTP {
    /// Accepts Microsoft's "Secret key" (any case, with or without spaces/dashes) or an
    /// otpauth:// URL. Returns the base32 secret, or nil if it isn't a usable key.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("otpauth://"),
           let comps = URLComponents(string: s),
           let secret = comps.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value {
            s = secret
        }
        s = s.uppercased().filter { !" -\t\n".contains($0) }
        while s.hasSuffix("=") { s.removeLast() }
        guard s.count >= 16, base32Decode(s) != nil else { return nil }
        return s
    }

    static func base32Decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }

    static func code(secret: String, at date: Date = Date()) -> String? {
        guard let key = base32Decode(secret) else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
        let o = Int(mac[mac.count - 1] & 0x0F)
        let bin = (UInt32(mac[o] & 0x7F) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        return String(format: "%06u", bin % 1_000_000)
    }

    /// Seconds until the current code changes.
    static func secondsLeft(at date: Date = Date()) -> Int {
        30 - Int(date.timeIntervalSince1970) % 30
    }
}

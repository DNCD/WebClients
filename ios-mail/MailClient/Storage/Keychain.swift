import Foundation
import Security

/// Minimal Keychain store for Codable values. Items are device-only and readable only while unlocked.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "MailClient"

    static func save<T: Encodable>(_ value: T, for key: String) throws {
        let data = try JSONEncoder().encode(value)
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// What we persist between launches: API tokens and derived key passphrases (never the password).
enum SessionStore {
    private static let tokensKey = "session.tokens"
    private static let passphrasesKey = "session.passphrases"

    static var tokens: SessionTokens? {
        get { Keychain.load(SessionTokens.self, for: tokensKey) }
        set {
            if let newValue { try? Keychain.save(newValue, for: tokensKey) } else { Keychain.delete(tokensKey) }
        }
    }

    static var passphrases: [String: String]? {
        get { Keychain.load([String: String].self, for: passphrasesKey) }
        set {
            if let newValue { try? Keychain.save(newValue, for: passphrasesKey) } else { Keychain.delete(passphrasesKey) }
        }
    }

    static func clear() {
        tokens = nil
        passphrases = nil
    }
}

import Foundation
import ProtonCoreCryptoGoImplementation
import ProtonCoreCryptoGoInterface

/// Wrappers over ProtonCore's GopenPGP / go-srp bindings (`CryptoGo`), which report errors through
/// `NSErrorPointer` and optional returns.
enum Crypto {
    static func setUp() {
        injectDefaultCryptoImplementation()
    }

    static func call<T>(_ body: (NSErrorPointer) -> T?) throws -> T {
        var error: NSError?
        let result = body(&error)
        if let error { throw error }
        guard let result else { throw CryptoError.unexpectedNil }
        return result
    }

    static func key(armored: String) throws -> CryptoKey {
        try call { CryptoGo.CryptoNewKeyFromArmored(armored, $0) }
    }

    static func keyRing(_ keys: [CryptoKey]) throws -> CryptoKeyRing {
        guard let first = keys.first else { throw CryptoError.noUsableKeys }
        let ring = try call { CryptoGo.CryptoNewKeyRing(first, $0) }
        for key in keys.dropFirst() {
            try ring.add(key)
        }
        return ring
    }

    /// Generates a locked private key (used by tests).
    static func generateKey(email: String, passphrase: String) throws -> String {
        try call { CryptoGo.HelperGenerateKey(email, email, Data(passphrase.utf8), "x25519", 0, $0) }
    }

    /// Key ring for encrypting to an armored key. Recipient keys from the API are already public;
    /// GopenPGP refuses `toPublic()` on those, so only private keys are converted.
    static func publicKeyRing(armored: String) throws -> CryptoKeyRing {
        let parsed = try key(armored: armored)
        return try keyRing([parsed.isPrivate() ? try parsed.toPublic() : parsed])
    }

    /// Key passphrase derivation, as in ProtonCore `LoginService.makePassphrases`: bcrypt the password
    /// with the key salt; the passphrase is the last 31 characters of the 60-character hash.
    static func keyPassphrase(password: String, keySalt: String?) throws -> String {
        guard let keySalt, let salt = Data(base64Encoded: keySalt) else {
            // Legacy keys without a salt are locked with the password itself.
            return password
        }
        let hash = try call { CryptoGo.SrpMailboxPassword(Data(password.utf8), salt, $0) }
        guard let string = String(data: hash, encoding: .utf8) else { throw CryptoError.unexpectedNil }
        return String(string.suffix(31))
    }

    static func decrypt(armored: String, with ring: CryptoKeyRing) throws -> String {
        let message = try call { CryptoGo.CryptoNewPGPMessageFromArmored(armored, $0) }
        return try ring.decrypt(message, verifyKey: nil, verifyTime: 0).getString()
    }

    static func generateSessionKey() throws -> CryptoSessionKey {
        try call { CryptoGo.CryptoGenerateSessionKey($0) }
    }

    static func plainMessage(_ text: String) throws -> CryptoPlainMessage {
        guard let message = CryptoGo.CryptoNewPlainMessageFromString(text) else { throw CryptoError.unexpectedNil }
        return message
    }

    static func armor(binaryMessage: Data) throws -> String {
        guard let message = CryptoGo.CryptoNewPGPMessage(binaryMessage) else { throw CryptoError.unexpectedNil }
        return try call { message.getArmored($0) }
    }
}

enum CryptoError: LocalizedError {
    case unexpectedNil
    case noUsableKeys
    case wrongMailboxPassword
    case missingAddressKeys(String)
    case serverProofMismatch

    var errorDescription: String? {
        switch self {
        case .unexpectedNil: return "A cryptographic operation failed."
        case .noUsableKeys: return "No usable encryption keys were found."
        case .wrongMailboxPassword: return "Incorrect mailbox password."
        case .missingAddressKeys(let email): return "Keys for \(email) could not be unlocked."
        case .serverProofMismatch: return "The server could not prove it knows your password. Sign-in was aborted."
        }
    }
}

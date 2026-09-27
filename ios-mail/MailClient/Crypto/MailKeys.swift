import Foundation
import ProtonCoreCryptoGoInterface

/// Unlocked user and address keys.
///
/// Proton's key hierarchy: the user key is locked with a passphrase derived from the (mailbox) password
/// and its salt. Each address key is locked with a random passphrase ("Token") encrypted to the user key,
/// or, for legacy accounts, with a passphrase derived like the user key's.
final class MailKeys {
    struct AddressKeys {
        /// All active keys, used to decrypt mail sent to any of them.
        let decryptionRing: CryptoKeyRing
        /// Primary key only, used for signing outgoing mail.
        let signingRing: CryptoKeyRing
        /// Public half of the primary key, used to encrypt drafts to ourselves.
        let encryptionRing: CryptoKeyRing
    }

    private let addressKeys: [String: AddressKeys]

    private init(addressKeys: [String: AddressKeys]) {
        self.addressKeys = addressKeys
    }

    func keys(forAddressID id: String) throws -> AddressKeys {
        guard let keys = addressKeys[id] else { throw CryptoError.missingAddressKeys(id) }
        return keys
    }

    /// Derives key passphrases from the password (only done at login; the result is what we persist,
    /// never the password itself).
    static func derivePassphrases(password: String, user: User, addresses: [Address], salts: [KeySalt]) throws -> [String: String] {
        let saltByKeyID = Dictionary(salts.map { ($0.id, $0.keySalt) }, uniquingKeysWith: { first, _ in first })
        let legacyAddressKeys = addresses.flatMap(\.keys).filter { $0.token == nil }
        var passphrases: [String: String] = [:]
        for key in user.keys + legacyAddressKeys {
            passphrases[key.id] = try Crypto.keyPassphrase(password: password, keySalt: saltByKeyID[key.id] ?? nil)
        }
        return passphrases
    }

    static func unlock(user: User, addresses: [Address], passphrases: [String: String]) throws -> MailKeys {
        let userKeys = user.keys.filter(\.isActive).compactMap { info -> CryptoKey? in
            guard let passphrase = passphrases[info.id] else { return nil }
            return try? Crypto.key(armored: info.privateKey).unlock(Data(passphrase.utf8))
        }
        guard !userKeys.isEmpty else { throw CryptoError.wrongMailboxPassword }
        let userRing = try Crypto.keyRing(userKeys)

        var result: [String: AddressKeys] = [:]
        for address in addresses {
            var unlocked: [(info: PrivateKeyInfo, key: CryptoKey)] = []
            for info in address.keys where info.isActive {
                let passphrase: String?
                if let token = info.token {
                    // The web client also verifies `Signature` over the token; we only decrypt it.
                    passphrase = try? Crypto.decrypt(armored: token, with: userRing)
                } else {
                    passphrase = passphrases[info.id]
                }
                guard let passphrase,
                      let key = try? Crypto.key(armored: info.privateKey).unlock(Data(passphrase.utf8)) else { continue }
                unlocked.append((info, key))
            }
            guard !unlocked.isEmpty else { continue }
            let primary = unlocked.first(where: { $0.info.isPrimary }) ?? unlocked[0]
            result[address.id] = AddressKeys(
                decryptionRing: try Crypto.keyRing(unlocked.map(\.key)),
                signingRing: try Crypto.keyRing([primary.key]),
                encryptionRing: try Crypto.keyRing([try primary.key.toPublic()])
            )
        }
        return MailKeys(addressKeys: result)
    }
}

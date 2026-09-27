import Foundation
import ProtonCoreCryptoGoInterface

/// How a recipient receives the message, resolved from `core/v4/keys/all`
/// (simplified from `getPublicKeysEmailHelperWithKT` in `packages/key-transparency`).
enum RecipientEncryption {
    /// Proton user: body session key encrypted to their key (`PACKAGE_TYPE.SEND_PM`).
    case proton(publicKey: String)
    /// Anyone else: the server receives the session key and delivers in clear (`PACKAGE_TYPE.SEND_CLEAR`).
    case clear
}

/// `PACKAGE_TYPE` in `packages/shared/lib/mail/mailSettings.ts`.
enum PackageType {
    static let sendPM = 1
    static let sendClear = 4
    static let sendClearMIME = 32
}

/// Builds encrypted bodies the way `packages/shared/lib/mail/send/sendEncrypt.ts` does, for a
/// plain-text message without attachments.
enum SendEncryption {
    /// Draft body: signed and encrypted with a fresh session key, which is itself encrypted to our own
    /// address key, then armored (`encryptDraftBodyPackage` → `armoredBody`).
    static func encryptDraftBody(_ body: String, keys: MailKeys.AddressKeys) throws -> String {
        let sessionKey = try Crypto.generateSessionKey()
        let dataPacket = try sessionKey.encryptAndSign(try Crypto.plainMessage(body), sign: keys.signingRing)
        let keyPacket = try keys.encryptionRing.encryptSessionKey(sessionKey)
        return try Crypto.armor(binaryMessage: keyPacket + dataPacket)
    }

    /// The `text/plain` send package: one encrypted body, plus per-recipient key packets
    /// (`generateTopPackages` + `attachSubPackages` + `encryptPackages`).
    static func plainTextPackage(body: String,
                                 recipients: [String: RecipientEncryption],
                                 keys: MailKeys.AddressKeys) throws -> [String: Any] {
        let sessionKey = try Crypto.generateSessionKey()
        let dataPacket = try sessionKey.encryptAndSign(try Crypto.plainMessage(body), sign: keys.signingRing)

        var addresses: [String: Any] = [:]
        var packageType = 0
        for (email, encryption) in recipients {
            switch encryption {
            case .proton(let publicKey):
                let keyPacket = try Crypto.publicKeyRing(armored: publicKey).encryptSessionKey(sessionKey)
                // `Signature` is 1 when every attachment is signed, which holds vacuously with none.
                addresses[email] = ["Type": PackageType.sendPM, "BodyKeyPacket": keyPacket.base64EncodedString(), "Signature": 1] as [String: Any]
                packageType |= PackageType.sendPM
            case .clear:
                addresses[email] = ["Type": PackageType.sendClear, "Signature": 0] as [String: Any]
                packageType |= PackageType.sendClear
            }
        }

        var package: [String: Any] = [
            "Addresses": addresses,
            "MIMEType": "text/plain",
            "Type": packageType,
            "Body": dataPacket.base64EncodedString(),
        ]
        if packageType & (PackageType.sendClear | PackageType.sendClearMIME) != 0 {
            guard let key = sessionKey.key else { throw CryptoError.unexpectedNil }
            package["BodyKey"] = ["Key": key.base64EncodedString(), "Algorithm": sessionKey.algo]
        }
        return package
    }
}

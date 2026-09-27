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
    /// An uploaded attachment and its session key, needed to give recipients access to it.
    struct AttachmentKey {
        let attachmentID: String
        let sessionKey: CryptoSessionKey
    }

    static func plainTextPackage(body: String,
                                 recipients: [String: RecipientEncryption],
                                 attachments: [AttachmentKey] = [],
                                 keys: MailKeys.AddressKeys) throws -> [String: Any] {
        let sessionKey = try Crypto.generateSessionKey()
        let dataPacket = try sessionKey.encryptAndSign(try Crypto.plainMessage(body), sign: keys.signingRing)

        var addresses: [String: Any] = [:]
        var packageType = 0
        for (email, encryption) in recipients {
            switch encryption {
            case .proton(let publicKey):
                let recipientRing = try Crypto.publicKeyRing(armored: publicKey)
                let keyPacket = try recipientRing.encryptSessionKey(sessionKey)
                var attachmentKeyPackets: [String: Any] = [:]
                for attachment in attachments {
                    attachmentKeyPackets[attachment.attachmentID] = try recipientRing.encryptSessionKey(attachment.sessionKey).base64EncodedString()
                }
                // `Signature` is 1 when every attachment is signed; ours always are.
                var address: [String: Any] = ["Type": PackageType.sendPM, "BodyKeyPacket": keyPacket.base64EncodedString(), "Signature": 1]
                if !attachmentKeyPackets.isEmpty { address["AttachmentKeyPackets"] = attachmentKeyPackets }
                addresses[email] = address
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
            // Binary, sent as a file part (the web client posts a Blob).
            "Body": dataPacket,
        ]
        if packageType & (PackageType.sendClear | PackageType.sendClearMIME) != 0 {
            guard let key = sessionKey.key else { throw CryptoError.unexpectedNil }
            package["BodyKey"] = ["Key": key.base64EncodedString(), "Algorithm": sessionKey.algo]
            var attachmentKeys: [String: Any] = [:]
            for attachment in attachments {
                guard let key = attachment.sessionKey.key else { throw CryptoError.unexpectedNil }
                attachmentKeys[attachment.attachmentID] = ["Key": key.base64EncodedString(), "Algorithm": attachment.sessionKey.algo]
            }
            if !attachmentKeys.isEmpty { package["AttachmentKeys"] = attachmentKeys }
        }
        return package
    }
}

/// Attachment encryption, as in `packages/shared/lib/mail/send/attachments.ts`: data encrypted with a
/// fresh session key, a detached signature, and the session key encrypted to our own address key.
enum AttachmentEncryption {
    struct Encrypted {
        let keyPacket: Data
        let dataPacket: Data
        let signature: Data
        let sessionKey: CryptoSessionKey
    }

    static func encrypt(_ data: Data, keys: MailKeys.AddressKeys) throws -> Encrypted {
        guard let plain = CryptoGo.CryptoNewPlainMessage(data) else { throw CryptoError.unexpectedNil }
        let sessionKey = try Crypto.generateSessionKey()
        let dataPacket = try sessionKey.encrypt(plain)
        guard let signature = try keys.signingRing.signDetached(plain).getBinary() else { throw CryptoError.unexpectedNil }
        let keyPacket = try keys.encryptionRing.encryptSessionKey(sessionKey)
        return Encrypted(keyPacket: keyPacket, dataPacket: dataPacket, signature: signature, sessionKey: sessionKey)
    }

    /// Decrypts a downloaded attachment (the data packet) using its key packets from the metadata.
    static func decrypt(_ dataPacket: Data, keyPackets: String, keys: MailKeys.AddressKeys) throws -> Data {
        let key = try sessionKey(keyPackets: keyPackets, keys: keys)
        guard let data = try key.decrypt(dataPacket).getBinary() else { throw CryptoError.unexpectedNil }
        return data
    }

    static func sessionKey(keyPackets: String, keys: MailKeys.AddressKeys) throws -> CryptoSessionKey {
        guard let keyPacket = Data(base64Encoded: keyPackets) else { throw CryptoError.unexpectedNil }
        return try keys.decryptionRing.decryptSessionKey(keyPacket)
    }
}

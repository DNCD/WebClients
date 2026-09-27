import Foundation

// Response models. Field names follow the Proton API (see `packages/shared/lib/interfaces`),
// camel-cased by `JSONDecoder.proton`.

// MARK: Auth

struct AuthInfoResponse: Decodable {
    let version: Int
    let modulus: String
    let serverEphemeral: String
    let salt: String?
    let srpSession: String
}

struct AuthResponse: Decodable {
    let uid: String
    let accessToken: String
    let refreshToken: String
    let serverProof: String
    let passwordMode: Int
    let twoFactor: TwoFactorInfo?

    enum CodingKeys: String, CodingKey {
        case uid, accessToken, refreshToken, serverProof, passwordMode
        case twoFactor = "2FA"
    }

    /// PasswordMode 2 means the account uses a separate mailbox password to unlock keys.
    var needsMailboxPassword: Bool { passwordMode == 2 }
}

struct TwoFactorInfo: Decodable {
    /// Bitmask: 1 = TOTP, 2 = FIDO2 security key.
    let enabled: Int

    var totp: Bool { enabled & 1 != 0 }
    var fido2Only: Bool { enabled & 2 != 0 && enabled & 1 == 0 }
}

struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}

// MARK: User & keys

struct UserResponse: Decodable {
    let user: User
}

struct User: Codable {
    let id: String
    let name: String?
    let displayName: String?
    let keys: [PrivateKeyInfo]
}

struct PrivateKeyInfo: Codable {
    let id: String
    let privateKey: String
    let primary: Int
    let active: Int?
    let flags: Int?
    /// Address keys created after key migration are protected by a token encrypted to the user key.
    let token: String?
    let signature: String?

    var isPrimary: Bool { primary == 1 }
    var isActive: Bool { (active ?? 1) == 1 }
}

struct KeySaltsResponse: Decodable {
    let keySalts: [KeySalt]
}

struct KeySalt: Decodable {
    let id: String
    let keySalt: String?
}

struct AddressesResponse: Decodable {
    let addresses: [Address]
}

struct Address: Codable, Identifiable, Hashable {
    let id: String
    let email: String
    let displayName: String?
    let status: Int
    let send: Int?
    let receive: Int?
    let order: Int?
    let keys: [PrivateKeyInfo]

    var canSend: Bool { status == 1 && (send ?? 1) == 1 }

    static func == (lhs: Address, rhs: Address) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PublicKeysResponse: Decodable {
    struct Group: Decodable {
        let keys: [PublicKeyInfo]
    }

    let address: Group
    let catchAll: Group?
    let unverified: Group?
}

struct PublicKeyInfo: Decodable {
    let publicKey: String
    let flags: Int
    let primary: Int?

    /// `KEY_FLAG` in `packages/shared/lib/constants.ts`.
    var canEncryptMail: Bool { flags & 2 != 0 && flags & 4 == 0 }
}

// MARK: Mail

struct Recipient: Codable, Hashable {
    let name: String
    let address: String

    var displayName: String { name.isEmpty ? address : name }

    var json: [String: Any] { ["Name": name, "Address": address] }
}

struct MessagesResponse: Decodable {
    let total: Int
    let messages: [MessageMetadata]
}

struct MessageMetadata: Codable, Identifiable, Hashable {
    let id: String
    let conversationID: String?
    let addressID: String
    let subject: String
    let sender: Recipient
    let toList: [Recipient]
    let ccList: [Recipient]?
    let time: TimeInterval
    let size: Int?
    var unread: Int
    let numAttachments: Int?
    let flags: Int?
    var labelIDs: [String]?

    var isUnread: Bool { unread == 1 }
    var date: Date { Date(timeIntervalSince1970: time) }
}

struct MessageResponse: Decodable {
    let message: MessageDetail
}

struct MessageDetail: Codable, Identifiable {
    let id: String
    let addressID: String
    let subject: String
    let sender: Recipient
    let toList: [Recipient]
    let ccList: [Recipient]?
    let bccList: [Recipient]?
    let time: TimeInterval
    let body: String
    let mimeType: String
    let attachments: [AttachmentInfo]?

    var date: Date { Date(timeIntervalSince1970: time) }
}

struct AttachmentInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int
    let mimeType: String
    /// Session key packet for the attachment, encrypted to the address key (base64).
    let keyPackets: String?
    let signature: String?
}

/// Custom label (Type 1) or folder (Type 3), from `core/v4/labels`.
struct MailLabel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let type: Int
    let parentID: String?
    let order: Int?
    /// Full path for nested folders ("Work/Clients"); Sieve `fileinto` uses it.
    let path: String?

    var isFolder: Bool { type == 3 }
}

struct LabelsResponse: Decodable {
    let labels: [MailLabel]
}

/// Mailbox system label IDs (`MAILBOX_LABEL_IDS` in `packages/shared/lib/constants.ts`).
enum Mailbox: String, CaseIterable, Identifiable {
    case inbox = "0"
    case drafts = "8"
    case sent = "7"
    case starred = "10"
    case archive = "6"
    case spam = "4"
    case trash = "3"
    case allMail = "5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .starred: return "Starred"
        case .archive: return "Archive"
        case .spam: return "Spam"
        case .trash: return "Trash"
        case .allMail: return "All Mail"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .starred: return "star"
        case .archive: return "archivebox"
        case .spam: return "xmark.octagon"
        case .trash: return "trash"
        case .allMail: return "envelope"
        }
    }
}

import Foundation

/// Mail operations, ported from `packages/shared/lib/api/messages.ts` and the send pipeline in
/// `packages/shared/lib/mail/send/`.
struct MailService {
    let api: APIClient
    let keys: MailKeys
    let addresses: [Address]

    static func load(api: APIClient, passphrases: [String: String]) async throws -> MailService {
        async let user: UserResponse = api.send(.get("core/v4/users"))
        async let addresses: AddressesResponse = api.send(.get("core/v4/addresses"))
        let (u, a) = try await (user.user, addresses.addresses)
        let keys = try MailKeys.unlock(user: u, addresses: a, passphrases: passphrases)
        let sorted = a.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        return MailService(api: api, keys: keys, addresses: sorted)
    }

    var sendableAddresses: [Address] { addresses.filter(\.canSend) }

    // MARK: Reading

    func messages(in mailbox: Mailbox, page: Int, pageSize: Int = 50, keyword: String? = nil) async throws -> MessagesResponse {
        var query = [
            URLQueryItem(name: "LabelID", value: mailbox.rawValue),
            URLQueryItem(name: "Page", value: String(page)),
            URLQueryItem(name: "PageSize", value: String(pageSize)),
            URLQueryItem(name: "Sort", value: "Time"),
            URLQueryItem(name: "Desc", value: "1"),
        ]
        if let keyword, !keyword.isEmpty {
            query.append(URLQueryItem(name: "Keyword", value: keyword))
        }
        return try await api.send(.get("mail/v4/messages", query: query))
    }

    func message(id: String) async throws -> MessageDetail {
        let response: MessageResponse = try await api.send(.get("mail/v4/messages/\(id)"))
        return response.message
    }

    /// Decrypts a message body into something displayable.
    func decryptBody(of message: MessageDetail) throws -> MessageContent {
        let ring = try keys.keys(forAddressID: message.addressID).decryptionRing
        let decrypted = try Crypto.decrypt(armored: message.body, with: ring)
        switch message.mimeType {
        case "text/html":
            return .html(decrypted)
        case "multipart/mixed":
            // PGP/MIME: the decrypted payload is a full MIME entity.
            return MIMEParser.content(of: decrypted)
        default:
            return .plain(decrypted)
        }
    }

    // MARK: Actions

    func markRead(_ ids: [String], read: Bool = true) async throws {
        try await api.sendRaw(.put(read ? "mail/v4/messages/read" : "mail/v4/messages/unread", ["IDs": ids]))
    }

    func move(_ ids: [String], to mailbox: Mailbox) async throws {
        try await api.sendRaw(.put("mail/v4/messages/label", ["LabelID": mailbox.rawValue, "IDs": ids]))
    }

    func delete(_ ids: [String]) async throws {
        try await api.sendRaw(.put("mail/v4/messages/delete", ["IDs": ids]))
    }

    // MARK: Sending

    struct Draft {
        var from: Address
        var to: [String]
        var cc: [String] = []
        var bcc: [String] = []
        var subject: String
        var body: String
    }

    /// Creates a draft, then sends it: `createDraft` followed by `sendFormatter` in the web client.
    func send(_ draft: Draft) async throws {
        let addressKeys = try keys.keys(forAddressID: draft.from.id)
        let recipients = Array(Set(draft.to + draft.cc + draft.bcc))
        guard !recipients.isEmpty else { throw SendError.noRecipients }

        var encryption: [String: RecipientEncryption] = [:]
        try await withThrowingTaskGroup(of: (String, RecipientEncryption).self) { group in
            for email in recipients {
                group.addTask { (email, try await self.recipientEncryption(for: email)) }
            }
            for try await (email, value) in group {
                encryption[email] = value
            }
        }

        let list = { (emails: [String]) in emails.map { Recipient(name: "", address: $0).json } }
        let created: MessageResponse = try await api.send(.post("mail/v4/messages", [
            "Message": [
                "AddressID": draft.from.id,
                "Sender": Recipient(name: draft.from.displayName ?? "", address: draft.from.email).json,
                "ToList": list(draft.to),
                "CCList": list(draft.cc),
                "BCCList": list(draft.bcc),
                "Subject": draft.subject,
                "MIMEType": "text/plain",
                "Body": try SendEncryption.encryptDraftBody(draft.body, keys: addressKeys),
            ] as [String: Any],
        ]))

        let package = try SendEncryption.plainTextPackage(body: draft.body, recipients: encryption, keys: addressKeys)
        var form = MultipartForm()
        form.appendNested("Packages", ["text/plain": package])
        try await api.sendRaw(APIRequest(method: .post, path: "mail/v4/messages/\(created.message.id)", body: .multipart(form)))
    }

    private func recipientEncryption(for email: String) async throws -> RecipientEncryption {
        do {
            let response: PublicKeysResponse = try await api.send(.get("core/v4/keys/all", query: [
                URLQueryItem(name: "Email", value: email),
            ]))
            let keys = response.address.keys + (response.catchAll?.keys ?? [])
            if let key = keys.first(where: \.canEncryptMail) {
                return .proton(publicKey: key.publicKey)
            }
            // External recipients (including ones with WKD or uploaded keys) get clear mail here;
            // PGP to external keys is not implemented.
            return .clear
        } catch let error as APIError where error.code == ProtonCode.keyGetDomainExternal {
            return .clear
        }
    }
}

enum MessageContent {
    case plain(String)
    case html(String)
}

enum SendError: LocalizedError {
    case noRecipients

    var errorDescription: String? { "Add at least one recipient." }
}

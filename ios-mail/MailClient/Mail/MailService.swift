import Foundation

/// Mail operations, ported from `packages/shared/lib/api/messages.ts` and the send pipeline in
/// `packages/shared/lib/mail/send/`.
struct MailService {
    let api: APIClient
    let keys: MailKeys
    let addresses: [Address]
    let store: MailStore

    /// Unlocks keys from fresh account data, or from the copy cached in the store when offline.
    static func load(api: APIClient, passphrases: [String: String], store: MailStore) async throws -> MailService {
        var user: User
        var addresses: [Address]
        do {
            async let userResponse: UserResponse = api.send(.get("core/v4/users"))
            async let addressesResponse: AddressesResponse = api.send(.get("core/v4/addresses"))
            (user, addresses) = try await (userResponse.user, addressesResponse.addresses)
            // Private keys are stored locked (as the server returns them), so caching them is safe.
            try? await store.setValue(String(data: try JSONEncoder().encode(user), encoding: .utf8), for: "user")
            try? await store.setValue(String(data: try JSONEncoder().encode(addresses), encoding: .utf8), for: "addresses")
        } catch where error.isTransientNetworkError {
            guard let userJSON = try await store.value("user"), let addressesJSON = try await store.value("addresses") else { throw error }
            user = try JSONDecoder().decode(User.self, from: Data(userJSON.utf8))
            addresses = try JSONDecoder().decode([Address].self, from: Data(addressesJSON.utf8))
        }
        addresses.sort { ($0.order ?? 0) < ($1.order ?? 0) }
        let keys = try MailKeys.unlock(user: user, addresses: addresses, passphrases: passphrases)
        let sorted = addresses.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        return MailService(api: api, keys: keys, addresses: sorted, store: store)
    }

    var sendableAddresses: [Address] { addresses.filter(\.canSend) }

    func owns(_ email: String) -> Bool {
        addresses.contains { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    // MARK: Reading

    func messages(labelID: String, page: Int, pageSize: Int = 50, search: SearchQuery = SearchQuery()) async throws -> MessagesResponse {
        var query = search.apiQuery(labelID: labelID)
        query += [
            URLQueryItem(name: "Page", value: String(page)),
            URLQueryItem(name: "PageSize", value: String(pageSize)),
            URLQueryItem(name: "Sort", value: "Time"),
            URLQueryItem(name: "Desc", value: "1"),
        ]
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

    /// Cached copy first (works offline); otherwise fetch, decrypt and cache.
    func loadBody(id: String) async throws -> (MessageDetail, MessageContent) {
        if let cached = try? await store.body(id: id) {
            return (cached.detail, cached.content.content)
        }
        let detail = try await message(id: id)
        let content = try decryptBody(of: detail)
        try? await store.saveBody(detail, content: content)
        return (detail, content)
    }

    func labels() async throws -> [MailLabel] {
        async let labels: LabelsResponse = api.send(.get("core/v4/labels", query: [URLQueryItem(name: "Type", value: "1")]))
        async let folders: LabelsResponse = api.send(.get("core/v4/labels", query: [URLQueryItem(name: "Type", value: "3")]))
        let all = try await labels.labels + folders.labels
        try? await store.saveLabels(all)
        return all
    }

    // MARK: Actions

    func markRead(_ ids: [String], read: Bool = true) async throws {
        try await api.sendRaw(.put(read ? "mail/v4/messages/read" : "mail/v4/messages/unread", ["IDs": ids]))
    }

    /// Moves to a folder or applies a label (`labelMessages`).
    func label(_ ids: [String], labelID: String) async throws {
        try await api.sendRaw(.put("mail/v4/messages/label", ["LabelID": labelID, "IDs": ids]))
    }

    func unlabel(_ ids: [String], labelID: String) async throws {
        try await api.sendRaw(.put("mail/v4/messages/unlabel", ["LabelID": labelID, "IDs": ids]))
    }

    func move(_ ids: [String], to mailbox: Mailbox) async throws {
        try await label(ids, labelID: mailbox.rawValue)
    }

    func delete(_ ids: [String]) async throws {
        try await api.sendRaw(.put("mail/v4/messages/delete", ["IDs": ids]))
    }

    // MARK: Attachments

    /// Downloads and decrypts an attachment into a temporary file named after it.
    func downloadAttachment(_ attachment: AttachmentInfo, of message: MessageDetail) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Attachments/\(attachment.id)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(Self.safeFilename(attachment.name))
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }

        guard let keyPackets = attachment.keyPackets else { throw CryptoError.unexpectedNil }
        let dataPacket = try await api.sendRaw(.get("mail/v4/attachments/\(attachment.id)"))
        let data = try AttachmentEncryption.decrypt(dataPacket, keyPackets: keyPackets,
                                                    keys: try keys.keys(forAddressID: message.addressID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return fileURL
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private func uploadAttachment(_ file: OutgoingAttachment, draftID: String, keys: MailKeys.AddressKeys) async throws -> SendEncryption.AttachmentKey {
        let encrypted = try AttachmentEncryption.encrypt(file.data, keys: keys)
        var form = MultipartForm()
        form.append("Filename", file.filename)
        form.append("MessageID", draftID)
        form.append("ContentID", "")
        form.append("MIMEType", file.mimeType)
        form.append("KeyPackets", data: encrypted.keyPacket)
        form.append("DataPacket", data: encrypted.dataPacket)
        form.append("Signature", data: encrypted.signature)
        let response: AttachmentResponse = try await api.send(APIRequest(method: .post, path: "mail/v4/attachments", body: .multipart(form)))
        return SendEncryption.AttachmentKey(attachmentID: response.attachment.id, sessionKey: encrypted.sessionKey)
    }

    // MARK: Sending

    /// Creates a draft, uploads attachments, then sends: `createDraft` → attachment upload →
    /// `sendFormatter` in the web client.
    func send(_ item: OutboxItem) async throws {
        guard let from = addresses.first(where: { $0.id == item.fromAddressID }) else { throw SendError.unknownSender }
        let addressKeys = try keys.keys(forAddressID: from.id)
        let recipients = Array(Set(item.to + item.cc + item.bcc))
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
                "AddressID": from.id,
                "Sender": Recipient(name: from.displayName ?? "", address: from.email).json,
                "ToList": list(item.to),
                "CCList": list(item.cc),
                "BCCList": list(item.bcc),
                "Subject": item.subject,
                "MIMEType": "text/plain",
                "Body": try SendEncryption.encryptDraftBody(item.body, keys: addressKeys),
            ] as [String: Any],
        ]))

        var attachmentKeys: [SendEncryption.AttachmentKey] = []
        for file in item.attachments {
            attachmentKeys.append(try await uploadAttachment(file, draftID: created.message.id, keys: addressKeys))
        }

        let package = try SendEncryption.plainTextPackage(body: item.body, recipients: encryption,
                                                          attachments: attachmentKeys, keys: addressKeys)
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

/// A file picked in the composer. Kept whole so queued (offline) mail can be sent later.
struct OutgoingAttachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

struct AttachmentResponse: Decodable {
    let attachment: AttachmentInfo
}

enum MessageContent {
    case plain(String)
    case html(String)
}

enum SendError: LocalizedError {
    case noRecipients
    case unknownSender

    var errorDescription: String? {
        switch self {
        case .noRecipients: return "Add at least one recipient."
        case .unknownSender: return "The sending address is no longer available."
        }
    }
}

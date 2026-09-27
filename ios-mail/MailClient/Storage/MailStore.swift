import CryptoKit
import Foundation

/// Per-account offline cache: message metadata, labels, decrypted bodies, a full-text index and the
/// outbox. The database file uses iOS data protection, and cached bodies are additionally sealed with
/// AES-GCM using a per-account key kept in the Keychain. The FTS index necessarily holds searchable
/// text; wiping the account (sign-out) deletes the whole file.
actor MailStore {
    private let db: SQLiteDatabase
    private let bodyKey: SymmetricKey
    let url: URL

    static func url(forAccount id: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "account"
        return base.appendingPathComponent("Accounts/\(safe)/mail.sqlite")
    }

    init(accountID: String) throws {
        url = Self.url(forAccount: accountID)
        db = try SQLiteDatabase(url: url)
        let keyName = "store.\(accountID).key"
        if let keyData = Keychain.load(Data.self, for: keyName) {
            bodyKey = SymmetricKey(data: keyData)
        } else {
            let key = SymmetricKey(size: .bits256)
            try Keychain.save(key.withUnsafeBytes { Data($0) }, for: keyName)
            bodyKey = key
        }
        try Self.migrate(db)
    }

    static func destroy(accountID: String) {
        let fileURL = url(forAccount: accountID)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        Keychain.delete("store.\(accountID).key")
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            time REAL NOT NULL,
            unread INTEGER NOT NULL,
            label_ids TEXT NOT NULL,
            json BLOB NOT NULL
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS messages_time ON messages(time DESC)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS bodies (
            id TEXT PRIMARY KEY,
            sealed BLOB NOT NULL,
            cached_at REAL NOT NULL
        )
        """)
        try db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
            id UNINDEXED, subject, sender, recipients, body,
            tokenize = 'unicode61 remove_diacritics 2'
        )
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS labels (id TEXT PRIMARY KEY, json BLOB NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS outbox (
            id TEXT PRIMARY KEY,
            created REAL NOT NULL,
            sealed BLOB NOT NULL,
            last_error TEXT
        )
        """)
    }

    // MARK: Messages

    func upsert(_ messages: [MessageMetadata]) throws {
        guard !messages.isEmpty else { return }
        let encoder = JSONEncoder()
        try db.transaction {
            for message in messages {
                try db.execute("""
                INSERT INTO messages (id, time, unread, label_ids, json) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET time = excluded.time, unread = excluded.unread,
                    label_ids = excluded.label_ids, json = excluded.json
                """, [.text(message.id), .double(message.time), .init(message.unread),
                      .text(Self.labelList(message.labelIDs ?? [])), .blob(try encoder.encode(message))])
                // Index metadata now; the body is added once it has been downloaded.
                if try db.query("SELECT 1 FROM bodies WHERE id = ?", [.text(message.id)]).isEmpty {
                    try index(message, body: "")
                }
            }
        }
    }

    /// Replaces what we have for a label with a fresh first page from the server, dropping cached
    /// messages that are newer than the page's oldest message but no longer in the label.
    func replaceFirstPage(_ messages: [MessageMetadata], labelID: String) throws {
        if let oldest = messages.map(\.time).min() {
            let keep = Set(messages.map(\.id))
            let stale = try db.query("SELECT id FROM messages WHERE label_ids LIKE ? AND time >= ?",
                                     [.text("%,\(labelID),%"), .double(oldest)])
                .compactMap { $0.string("id") }
                .filter { !keep.contains($0) }
            try remove(stale)
        }
        try upsert(messages)
    }

    func messages(labelID: String, limit: Int, offset: Int = 0) throws -> [MessageMetadata] {
        try decodeMessages(db.query("SELECT json FROM messages WHERE label_ids LIKE ? ORDER BY time DESC LIMIT ? OFFSET ?",
                                    [.text("%,\(labelID),%"), .init(limit), .init(offset)]))
    }

    func message(id: String) throws -> MessageMetadata? {
        try decodeMessages(db.query("SELECT json FROM messages WHERE id = ?", [.text(id)])).first
    }

    func remove(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.execute("DELETE FROM messages WHERE id = ?", [.text(id)])
                try db.execute("DELETE FROM bodies WHERE id = ?", [.text(id)])
                try db.execute("DELETE FROM search WHERE id = ?", [.text(id)])
            }
        }
    }

    func update(_ id: String, _ change: (inout MessageMetadata) -> Void) throws {
        guard var current = try message(id: id) else { return }
        change(&current)
        try upsert([current])
    }

    func unreadCount(labelID: String) throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM messages WHERE unread = 1 AND label_ids LIKE ?", [.text("%,\(labelID),%")])
            .first?.int("n") ?? 0
    }

    func clearMessages() throws {
        try db.transaction {
            try db.execute("DELETE FROM messages")
            try db.execute("DELETE FROM bodies")
            try db.execute("DELETE FROM search")
        }
    }

    // MARK: Bodies

    struct CachedBody: Codable {
        var detail: MessageDetail
        var content: CachedContent
    }

    enum CachedContent: Codable {
        case plain(String)
        case html(String)

        init(_ content: MessageContent) {
            switch content {
            case .plain(let text): self = .plain(text)
            case .html(let html): self = .html(html)
            }
        }

        var content: MessageContent {
            switch self {
            case .plain(let text): return .plain(text)
            case .html(let html): return .html(html)
            }
        }
    }

    func saveBody(_ detail: MessageDetail, content: MessageContent) throws {
        let data = try JSONEncoder().encode(CachedBody(detail: detail, content: CachedContent(content)))
        let sealed = try AES.GCM.seal(data, using: bodyKey).combined!
        try db.transaction {
            try db.execute("INSERT OR REPLACE INTO bodies (id, sealed, cached_at) VALUES (?, ?, ?)",
                           [.text(detail.id), .blob(sealed), .double(Date().timeIntervalSince1970)])
            if let metadata = try message(id: detail.id) {
                try index(metadata, body: Self.searchableText(content))
            }
        }
    }

    func body(id: String) throws -> CachedBody? {
        guard let sealed = try db.query("SELECT sealed FROM bodies WHERE id = ?", [.text(id)]).first?.data("sealed") else {
            return nil
        }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: bodyKey)
        return try JSONDecoder().decode(CachedBody.self, from: data)
    }

    /// Recent messages whose bodies are not cached yet, newest first.
    func messagesMissingBodies(since: Date, limit: Int) throws -> [MessageMetadata] {
        try decodeMessages(db.query("""
            SELECT m.json FROM messages m LEFT JOIN bodies b ON b.id = m.id
            WHERE b.id IS NULL AND m.time >= ? ORDER BY m.time DESC LIMIT ?
            """, [.double(since.timeIntervalSince1970), .init(limit)]))
    }

    func cachedBodyCount() throws -> Int {
        try db.query("SELECT COUNT(*) AS n FROM bodies").first?.int("n") ?? 0
    }

    // MARK: Search

    /// Full-text search over subject, sender, recipients and cached bodies (FTS5 query syntax).
    func search(_ ftsQuery: String, limit: Int = 200) throws -> [MessageMetadata] {
        try decodeMessages(db.query("""
            SELECT m.json FROM search s JOIN messages m ON m.id = s.id
            WHERE search MATCH ? ORDER BY m.time DESC LIMIT ?
            """, [.text(ftsQuery), .init(limit)]))
    }

    private func index(_ message: MessageMetadata, body: String) throws {
        try db.execute("DELETE FROM search WHERE id = ?", [.text(message.id)])
        let recipients = (message.toList + (message.ccList ?? [])).map { "\($0.name) \($0.address)" }.joined(separator: " ")
        try db.execute("INSERT INTO search (id, subject, sender, recipients, body) VALUES (?, ?, ?, ?, ?)",
                       [.text(message.id), .text(message.subject), .text("\(message.sender.name) \(message.sender.address)"),
                        .text(recipients), .text(body)])
    }

    static func searchableText(_ content: MessageContent) -> String {
        switch content {
        case .plain(let text): return text
        case .html(let html): return html.strippingHTML()
        }
    }

    // MARK: Labels

    func saveLabels(_ labels: [MailLabel]) throws {
        let encoder = JSONEncoder()
        try db.transaction {
            try db.execute("DELETE FROM labels")
            for label in labels {
                try db.execute("INSERT INTO labels (id, json) VALUES (?, ?)", [.text(label.id), .blob(try encoder.encode(label))])
            }
        }
    }

    func labels() throws -> [MailLabel] {
        let decoder = JSONDecoder()
        return try db.query("SELECT json FROM labels").compactMap { row in
            try row.data("json").map { try decoder.decode(MailLabel.self, from: $0) }
        }
    }

    // MARK: Key-value

    func value(_ key: String) throws -> String? {
        try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.string("value")
    }

    func setValue(_ value: String?, for key: String) throws {
        if let value {
            try db.execute("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    // MARK: Outbox

    func enqueue(_ item: OutboxItem) throws {
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(item), using: bodyKey).combined!
        try db.execute("INSERT OR REPLACE INTO outbox (id, created, sealed, last_error) VALUES (?, ?, ?, ?)",
                       [.text(item.id), .double(item.created.timeIntervalSince1970), .blob(sealed), .init(item.lastError)])
    }

    func outbox() throws -> [OutboxItem] {
        try db.query("SELECT sealed FROM outbox ORDER BY created").compactMap { row in
            guard let sealed = row.data("sealed") else { return nil }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: bodyKey)
            return try JSONDecoder().decode(OutboxItem.self, from: data)
        }
    }

    func removeFromOutbox(_ id: String) throws {
        try db.execute("DELETE FROM outbox WHERE id = ?", [.text(id)])
    }

    // MARK: Helpers

    private func decodeMessages(_ rows: [SQLiteDatabase.Row]) throws -> [MessageMetadata] {
        let decoder = JSONDecoder()
        return try rows.compactMap { row in try row.data("json").map { try decoder.decode(MessageMetadata.self, from: $0) } }
    }

    /// `,0,5,10,` so a label can be matched with `LIKE '%,0,%'`.
    static func labelList(_ ids: [String]) -> String {
        "," + ids.joined(separator: ",") + ","
    }
}

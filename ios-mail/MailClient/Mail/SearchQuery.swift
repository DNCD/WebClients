import Foundation

/// Gmail-style search operators, mapped onto the API's search params (`queryMessageMetadata` in
/// `packages/shared/lib/api/messages.ts`) and onto the local full-text index.
///
/// Supported: `from:` `to:` `subject:` `in:` `has:attachment` `is:unread|read|starred`
/// `before:YYYY-MM-DD` `after:YYYY-MM-DD` `newer_than:7d|2w|3m|1y` `"exact phrase"` `-excluded`
/// and free words (matched in subject, people and, for downloaded mail, the body).
struct SearchQuery: Equatable {
    var words: [String] = []
    var phrases: [String] = []
    var excluded: [String] = []
    var from: String?
    var to: String?
    var subject: String?
    var mailbox: String?
    var hasAttachment: Bool?
    var unread: Bool?
    var starred: Bool?
    var after: Date?
    var before: Date?

    var isEmpty: Bool { self == SearchQuery() }

    /// Anything the server can't evaluate (it cannot read encrypted bodies).
    var needsLocalIndex: Bool { !words.isEmpty || !phrases.isEmpty || !excluded.isEmpty }

    init() {}

    init(_ text: String) {
        for token in Self.tokenize(text) {
            if token.quoted {
                phrases.append(token.text)
                continue
            }
            let raw = token.text
            if raw.hasPrefix("-"), raw.count > 1 {
                excluded.append(String(raw.dropFirst()))
                continue
            }
            guard let colon = raw.firstIndex(of: ":"), colon != raw.startIndex else {
                words.append(raw)
                continue
            }
            let key = raw[..<colon].lowercased()
            let value = String(raw[raw.index(after: colon)...])
            switch (key, value.lowercased()) {
            case ("from", _): from = value
            case ("to", _): to = value
            case ("subject", _): subject = value
            case ("in", _), ("label", _): mailbox = value
            case ("has", "attachment"), ("has", "attachments"): hasAttachment = true
            case ("is", "unread"): unread = true
            case ("is", "read"): unread = false
            case ("is", "starred"): starred = true
            case ("before", _): before = Self.date(value)
            case ("after", _): after = Self.date(value)
            case ("newer_than", _): after = Self.relativeDate(value)
            case ("older_than", _): before = Self.relativeDate(value)
            default: words.append(raw)
            }
        }
    }

    /// Resolves `in:` to a system mailbox, if it names one.
    var systemMailbox: Mailbox? {
        guard let mailbox else { return nil }
        let name = mailbox.lowercased().replacingOccurrences(of: "_", with: " ")
        return Mailbox.allCases.first { $0.title.lowercased() == name || $0.rawValue == name }
    }

    /// Query items for `GET mail/v4/messages`.
    func apiQuery(labelID: String) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "LabelID", value: labelID)]
        if let from { items.append(.init(name: "From", value: from)) }
        if let to { items.append(.init(name: "Recipients", value: to)) }
        if let subject { items.append(.init(name: "Subject", value: subject)) }
        let keyword = (words + phrases).joined(separator: " ")
        if !keyword.isEmpty { items.append(.init(name: "Keyword", value: keyword)) }
        if hasAttachment == true { items.append(.init(name: "Attachments", value: "1")) }
        if let unread { items.append(.init(name: "Unread", value: unread ? "1" : "0")) }
        if starred == true { items.append(.init(name: "Starred", value: "1")) }
        if let after { items.append(.init(name: "Begin", value: String(Int(after.timeIntervalSince1970)))) }
        if let before { items.append(.init(name: "End", value: String(Int(before.timeIntervalSince1970)))) }
        return items
    }

    /// FTS5 expression for the local index, or nil when only metadata filters were given.
    var ftsQuery: String? {
        var terms: [String] = []
        for word in words { terms.append(Self.ftsTerm(word, prefix: true)) }
        for phrase in phrases { terms.append(Self.ftsTerm(phrase, prefix: false)) }
        if let from { terms.append("sender : " + Self.ftsTerm(from, prefix: true)) }
        if let to { terms.append("recipients : " + Self.ftsTerm(to, prefix: true)) }
        if let subject { terms.append("subject : " + Self.ftsTerm(subject, prefix: true)) }
        guard !terms.isEmpty else { return nil }
        var query = terms.joined(separator: " AND ")
        for word in excluded { query += " NOT " + Self.ftsTerm(word, prefix: false) }
        return query
    }

    /// Filters local results for the metadata operators the FTS index doesn't cover.
    func matches(_ message: MessageMetadata) -> Bool {
        if let unread, message.isUnread != unread { return false }
        if starred == true, !(message.labelIDs ?? []).contains(Mailbox.starred.rawValue) { return false }
        if hasAttachment == true, (message.numAttachments ?? 0) == 0 { return false }
        if let after, message.date < after { return false }
        if let before, message.date >= before { return false }
        if let mailbox = systemMailbox, !(message.labelIDs ?? []).contains(mailbox.rawValue) { return false }
        return true
    }

    // MARK: Parsing helpers

    private struct Token { let text: String; let quoted: Bool }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        // key:"quoted value" stays one operator token, e.g. subject:"weekly report".
        var quotedOperatorValue = false
        func flush(quoted: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { tokens.append(Token(text: trimmed, quoted: quoted)) }
            current = ""
        }
        for character in text {
            if character == "\"" {
                if inQuotes {
                    flush(quoted: !quotedOperatorValue)
                    inQuotes = false
                    quotedOperatorValue = false
                } else if current.hasSuffix(":") {
                    inQuotes = true
                    quotedOperatorValue = true
                } else {
                    flush(quoted: false)
                    inQuotes = true
                }
            } else if character.isWhitespace && !inQuotes {
                flush(quoted: false)
            } else {
                current.append(character)
            }
        }
        flush(quoted: inQuotes && !quotedOperatorValue)
        return tokens
    }

    private static func ftsTerm(_ text: String, prefix: Bool) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"" + (prefix && !text.contains(" ") ? "*" : "")
    }

    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func relativeDate(_ text: String, now: Date = Date()) -> Date? {
        guard let unit = text.last, let amount = Int(text.dropLast()) else { return nil }
        let component: Calendar.Component
        switch unit {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        case "y": component = .year
        default: return nil
        }
        return Calendar.current.date(byAdding: component, value: -amount, to: now)
    }
}

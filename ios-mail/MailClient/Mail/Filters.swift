import Foundation

/// A server-side filter (`mail/v4/filters`), see `packages/sieve/src/filterModel.ts`.
struct MailFilter: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let status: Int
    let priority: Int?
    let version: Int?
    let sieve: String?

    var isEnabled: Bool { status == 1 }
}

struct FiltersResponse: Decodable {
    let filters: [MailFilter]
}

struct FilterResponse: Decodable {
    let filter: MailFilter
}

/// The web client's "simple filter" model, turned into Sieve text.
struct SimpleFilter: Equatable {
    enum Operator: String, CaseIterable, Identifiable {
        case all, any
        var id: String { rawValue }
        var title: String { self == .all ? "All conditions" : "Any condition" }
    }

    /// `ConditionType` in `filterModel.ts`.
    enum ConditionType: String, CaseIterable, Identifiable {
        case sender, recipient, subject, attachments
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sender: return "Sender"
            case .recipient: return "Recipient"
            case .subject: return "Subject"
            case .attachments: return "Attachments"
            }
        }
    }

    /// `ConditionComparator` in `filterModel.ts`.
    enum Comparator: String, CaseIterable, Identifiable {
        case contains, `is`, starts, ends, notContains = "!contains", isNot = "!is"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .contains: return "contains"
            case .is: return "is exactly"
            case .starts: return "begins with"
            case .ends: return "ends with"
            case .notContains: return "does not contain"
            case .isNot: return "is not"
            }
        }
    }

    struct Condition: Identifiable, Equatable {
        var id = UUID()
        var type: ConditionType = .sender
        var comparator: Comparator = .contains
        var value = ""
        /// For `.attachments`: true = "has attachments".
        var hasAttachments = true
    }

    var name = ""
    var matching: Operator = .all
    var conditions: [Condition] = [Condition()]
    /// Folder (system folder name like "archive", or custom folder path).
    var moveTo: String?
    var labels: [String] = []
    var markRead = false
    var star = false

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !conditions.isEmpty
            && conditions.allSatisfy { $0.type == .attachments || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            && (moveTo != nil || !labels.isEmpty || markRead || star)
    }

    /// Sieve (Version 2) equivalent to what the server compiles from the web's filter tree
    /// (`toSieveTree` in `packages/sieve`), including the "skip spam" prologue.
    var sieve: String {
        let tests = conditions.map(Self.test).joined(separator: ", ")
        var actions: [String] = []
        for folder in [moveTo].compactMap({ $0 }) + labels {
            actions.append("fileinto \(Self.quote(folder));")
        }
        var flags: [String] = []
        if markRead { flags.append(#""\\Seen""#) }
        if star { flags.append(#""\\Flagged""#) }
        if !flags.isEmpty {
            actions.append("addflag \(flags.count == 1 ? flags[0] : "[\(flags.joined(separator: ", "))]");")
            actions.append("keep;")
        }
        return """
        require ["include", "environment", "variables", "relational", "comparator-i;ascii-numeric", "spamtest"];
        require ["fileinto", "imap4flags"];

        # Generated: Do not run this script on spam messages
        if allof (environment :matches "vnd.proton.spam-threshold" "*",
        spamtest :value "ge" :comparator "i;ascii-numeric" "${1}")
        {
            return;
        }

        /**
         * @type \(matching == .all ? "and" : "or")
         */
        if \(matching == .all ? "allof" : "anyof") (\(tests)) {
            \(actions.joined(separator: "\n    "))
        }

        """
    }

    private static func test(_ condition: Condition) -> String {
        if condition.type == .attachments {
            return condition.hasAttachments ? #"exists "X-Attached""# : #"not exists "X-Attached""#
        }
        let negated = condition.comparator.rawValue.hasPrefix("!")
        let base = negated ? String(condition.comparator.rawValue.dropFirst()) : condition.comparator.rawValue
        let value = condition.value.trimmingCharacters(in: .whitespaces)
        let (match, key): (String, String)
        switch base {
        case "starts": (match, key) = (":matches", escapeWildcards(value) + "*")
        case "ends": (match, key) = (":matches", "*" + escapeWildcards(value))
        case "is": (match, key) = (":is", value)
        default: (match, key) = (":contains", value)
        }
        let test: String
        switch condition.type {
        case .sender:
            test = #"address :all :comparator "i;unicode-casemap" \#(match) "From" \#(quote(key))"#
        case .recipient:
            test = #"address :all :comparator "i;unicode-casemap" \#(match) ["To", "Cc", "Bcc"] \#(quote(key))"#
        case .subject:
            test = #"header :comparator "i;unicode-casemap" \#(match) "Subject" \#(quote(key))"#
        case .attachments:
            test = ""
        }
        return negated ? "not \(test)" : test
    }

    /// `escapeCharacters` in `toSieveTree.helpers.ts`.
    private static func escapeWildcards(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct SieveCheckResponse: Decodable {
    struct Issue: Decodable {
        let message: String?
    }
    let issues: [Issue]?
}

extension MailService {
    func filters() async throws -> [MailFilter] {
        let response: FiltersResponse = try await api.send(.get("mail/v4/filters"))
        return response.filters.sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
    }

    func setFilter(_ id: String, enabled: Bool) async throws {
        try await api.sendRaw(APIRequest(method: .put, path: "mail/v4/filters/\(id)/\(enabled ? "enable" : "disable")"))
    }

    func deleteFilter(_ id: String) async throws {
        try await api.sendRaw(APIRequest(method: .delete, path: "mail/v4/filters/\(id)"))
    }

    /// Validates with `mail/v4/filters/check`, then creates the filter (Version 2 Sieve).
    func createFilter(_ filter: SimpleFilter) async throws -> MailFilter {
        let check: SieveCheckResponse = try await api.send(.put("mail/v4/filters/check", ["Sieve": filter.sieve, "Version": 2]))
        if let issue = check.issues?.first {
            throw FilterError.invalid(issue.message ?? "The server rejected this filter.")
        }
        let response: FilterResponse = try await api.send(.post("mail/v4/filters", [
            "ID": "",
            "Name": filter.name,
            "Status": 1,
            "Version": 2,
            "Sieve": filter.sieve,
        ]))
        return response.filter
    }
}

enum FilterError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

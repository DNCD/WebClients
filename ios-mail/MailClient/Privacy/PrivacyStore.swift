import Foundation
import Observation

/// Counts shown as the shield badge in the message list.
struct PrivacySummary: Codable, Hashable {
    var trackers: Int
    var links: Int

    var total: Int { trackers + links }
}

/// Remembers, per message ID, how many trackers were blocked, so the list can badge messages once
/// they have been opened. Only counts are stored, never message content.
@MainActor
@Observable
final class PrivacyStore {
    private static let defaultsKey = "privacy.summaries"
    private static let limit = 2000

    private struct Entry: Codable {
        var summary: PrivacySummary
        var updated: Date
    }

    private var entries: [String: Entry]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
        entries = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func summary(for messageID: String) -> PrivacySummary? {
        entries[messageID]?.summary
    }

    func record(_ summary: PrivacySummary, for messageID: String) {
        guard entries[messageID]?.summary != summary else { return }
        entries[messageID] = Entry(summary: summary, updated: Date())
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.updated < $1.value.updated }.prefix(entries.count - Self.limit)
            for (id, _) in oldest { entries[id] = nil }
        }
        save()
    }

    func clear() {
        entries = [:]
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

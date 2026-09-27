import Foundation
import Observation

/// Mail events (`core/v5/events/{id}`), see `applications/mail/src/app/models/event.ts`.
struct EventsResponse: Decodable {
    struct MessageEvent: Decodable {
        let id: String
        let action: Int
        let message: MessageChange?
    }

    /// Full metadata on create; a partial update otherwise.
    struct MessageChange: Decodable {
        let unread: Int?
        let labelIDs: [String]?
        let labelIDsAdded: [String]?
        let labelIDsRemoved: [String]?
    }

    struct LabelCount: Decodable {
        let labelID: String?
        let unread: Int?
        let total: Int?
    }

    let eventID: String
    let more: Int?
    let refresh: Int?
    let messages: [MessageEvent]?
    let messageCounts: [LabelCount]?
    let labels: [LabelEvent]?

    struct LabelEvent: Decodable {
        let id: String
        let action: Int
    }
}

/// `EVENT_ACTIONS` in `packages/shared/lib/constants.ts`.
enum EventAction {
    static let delete = 0
    static let create = 1
    static let update = 2
    static let updateFlags = 3
}

/// Keeps an account's offline store current: first pages per mailbox, the event loop for incremental
/// changes, body downloads for offline reading and full-text search, and flushing the outbox.
@MainActor
@Observable
final class SyncEngine {
    let accountID: String
    let service: MailService
    let store: MailStore
    private let settings: AppSettings

    /// Bumped whenever cached data changes, so lists re-read the store.
    private(set) var revision = 0
    private(set) var isSyncing = false
    private(set) var isDownloadingBodies = false
    private(set) var cachedBodyCount = 0
    private(set) var unreadCounts: [String: Int] = [:]
    private(set) var outbox: [OutboxItem] = []
    private(set) var lastSyncError: String?
    private(set) var labels: [MailLabel] = []

    /// New messages seen by the event loop, for notifications.
    var onNewMessages: (([MessageMetadata]) -> Void)?

    private var pollTask: Task<Void, Never>?
    private static let pollInterval: Duration = .seconds(30)

    init(account accountID: String, service: MailService, store: MailStore, settings: AppSettings) {
        self.accountID = accountID
        self.service = service
        self.store = store
        self.settings = settings
    }

    func start() async {
        outbox = (try? await store.outbox()) ?? []
        labels = (try? await store.labels()) ?? []
        cachedBodyCount = (try? await store.cachedBodyCount()) ?? 0
        NetworkMonitor.shared.whenReconnected { [weak self] in
            Task { await self?.syncNow() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One sync round: events, outbox, labels, then body downloads. Safe to call often.
    func syncNow() async {
        guard !isSyncing, NetworkMonitor.shared.isOnline else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            await flushPendingActions()
            try await pollEvents()
            await flushOutbox()
            if labels.isEmpty { labels = (try? await service.labels()) ?? labels }
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }
        Task { await downloadBodies() }
    }

    // MARK: Mailbox pages

    /// Refreshes the first page of a mailbox from the server into the store.
    func refresh(labelID: String) async throws {
        let response = try await service.messages(labelID: labelID, page: 0)
        try await store.replaceFirstPage(response.messages, labelID: labelID)
        bump()
    }

    func loadPage(labelID: String, page: Int) async throws -> Int {
        let response = try await service.messages(labelID: labelID, page: page)
        try await store.upsert(response.messages)
        bump()
        return response.total
    }

    // MARK: Events

    private func pollEvents() async throws {
        guard let eventID = try await store.value("eventID") else {
            // First run: start the event loop from now; mailbox pages fill the store.
            let latest: LatestEventResponse = try await service.api.send(.get("core/v4/events/latest"))
            try await store.setValue(latest.eventID, for: "eventID")
            return
        }
        var current = eventID
        var more = true
        while more {
            let events: EventsResponse = try await service.api.send(.get("core/v5/events/\(current)", query: [
                URLQueryItem(name: "MessageCounts", value: "1"),
                URLQueryItem(name: "ConversationCounts", value: "0"),
            ]))
            if let refresh = events.refresh, refresh & 1 != 0 {
                // The server asks for a full mail resync (EVENT_ERRORS.MAIL / ALL).
                try await store.clearMessages()
                try await store.setValue(events.eventID, for: "eventID")
                bump()
                return
            }
            try await apply(events)
            current = events.eventID
            try await store.setValue(current, for: "eventID")
            more = events.more == 1
        }
    }

    private func apply(_ events: EventsResponse) async throws {
        var created: [String] = []
        for event in events.messages ?? [] {
            switch event.action {
            case EventAction.delete:
                try await store.remove([event.id])
            case EventAction.create:
                created.append(event.id)
            default:
                guard let change = event.message else { continue }
                try await store.update(event.id) { message in
                    if let unread = change.unread { message.unread = unread }
                    var labels = Set(change.labelIDs ?? message.labelIDs ?? [])
                    labels.formUnion(change.labelIDsAdded ?? [])
                    labels.subtract(change.labelIDsRemoved ?? [])
                    message.labelIDs = Array(labels)
                }
            }
        }
        if !created.isEmpty {
            // Event payloads use the full Message shape; fetch list metadata for the new IDs.
            let fresh = try await metadata(ids: created)
            try await store.upsert(fresh)
            // Anything received (not our own sent mail or drafts); NotificationManager applies the rules.
            let ownLabels: Set<String> = [Mailbox.sent.rawValue, Mailbox.drafts.rawValue, "1", "2", Mailbox.spam.rawValue, Mailbox.trash.rawValue]
            let incoming = fresh.filter { $0.isUnread && Set($0.labelIDs ?? []).isDisjoint(with: ownLabels) }
            if !incoming.isEmpty { onNewMessages?(incoming) }
        }
        for count in events.messageCounts ?? [] {
            if let labelID = count.labelID, let unread = count.unread { unreadCounts[labelID] = unread }
        }
        if events.labels?.isEmpty == false {
            labels = (try? await service.labels()) ?? labels
        }
        if !(events.messages ?? []).isEmpty { bump() }
    }

    private func metadata(ids: [String]) async throws -> [MessageMetadata] {
        var result: [MessageMetadata] = []
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let query = chunk.map { URLQueryItem(name: "ID[]", value: $0) } + [URLQueryItem(name: "LabelID", value: Mailbox.allMail.rawValue)]
            let response: MessagesResponse = try await service.api.send(.get("mail/v4/messages", query: query))
            result += response.messages
        }
        return result
    }

    // MARK: Offline bodies

    /// Downloads and decrypts recent messages so they can be read and full-text searched offline.
    func downloadBodies() async {
        guard !isDownloadingBodies, NetworkMonitor.shared.isOnline else { return }
        isDownloadingBodies = true
        defer { isDownloadingBodies = false }
        let since = Calendar.current.date(byAdding: .day, value: -settings.offlineDays, to: Date()) ?? Date()
        while NetworkMonitor.shared.isOnline, !Task.isCancelled {
            guard let batch = try? await store.messagesMissingBodies(since: since, limit: 10), !batch.isEmpty else { break }
            var progressed = false
            for message in batch {
                if (try? await service.loadBody(id: message.id)) != nil { progressed = true }
            }
            cachedBodyCount = (try? await store.cachedBodyCount()) ?? cachedBodyCount
            if !progressed { break }
        }
    }

    // MARK: Outbox

    /// Sends now if possible; queues on a network failure (or when offline).
    func send(_ item: OutboxItem) async throws {
        guard NetworkMonitor.shared.isOnline else {
            try await queue(item)
            return
        }
        do {
            try await service.send(item)
        } catch where error.isTransientNetworkError {
            var failed = item
            failed.lastError = error.localizedDescription
            try await queue(failed)
        }
    }

    func removeFromOutbox(_ id: String) async {
        try? await store.removeFromOutbox(id)
        outbox.removeAll { $0.id == id }
    }

    private func queue(_ item: OutboxItem) async throws {
        try await store.enqueue(item)
        outbox = try await store.outbox()
    }

    func flushOutbox() async {
        for item in outbox {
            do {
                try await service.send(item)
                try await store.removeFromOutbox(item.id)
            } catch where error.isTransientNetworkError {
                break
            } catch {
                var failed = item
                failed.lastError = error.localizedDescription
                try? await store.enqueue(failed)
            }
        }
        outbox = (try? await store.outbox()) ?? outbox
    }

    // MARK: Actions (work offline)

    /// Applies an action locally at once, then on the server; if offline (or the network fails) it is
    /// queued and replayed on the next sync.
    func perform(_ action: MailAction) async {
        await applyLocally(action)
        do {
            guard NetworkMonitor.shared.isOnline else { throw URLError(.notConnectedToInternet) }
            try await action.run(on: service)
        } catch where error.isTransientNetworkError {
            var pending = await pendingActions()
            pending.append(action)
            await savePendingActions(pending)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func flushPendingActions() async {
        var pending = await pendingActions()
        while let action = pending.first {
            do {
                try await action.run(on: service)
            } catch where error.isTransientNetworkError {
                break
            } catch {
                // Dropped: e.g. the message no longer exists.
            }
            pending.removeFirst()
            await savePendingActions(pending)
        }
    }

    private func pendingActions() async -> [MailAction] {
        guard let json = try? await store.value("pendingActions") else { return [] }
        return (try? JSONDecoder().decode([MailAction].self, from: Data(json.utf8))) ?? []
    }

    private func savePendingActions(_ actions: [MailAction]) async {
        let json = (try? JSONEncoder().encode(actions)).flatMap { String(data: $0, encoding: .utf8) }
        try? await store.setValue(actions.isEmpty ? nil : json, for: "pendingActions")
    }

    private func applyLocally(_ action: MailAction) async {
        let folderIDs = Set(labels.filter(\.isFolder).map(\.id)).union(MailAction.systemFolderIDs)
        switch action {
        case .markRead(let ids, let read):
            for id in ids { try? await store.update(id) { $0.unread = read ? 0 : 1 } }
        case .label(let ids, let labelID):
            let isFolder = folderIDs.contains(labelID)
            for id in ids {
                try? await store.update(id) { message in
                    var labels = Set(message.labelIDs ?? [])
                    if isFolder { labels.subtract(folderIDs) }
                    labels.insert(labelID)
                    message.labelIDs = Array(labels)
                }
            }
        case .unlabel(let ids, let labelID):
            for id in ids {
                try? await store.update(id) { message in
                    message.labelIDs = (message.labelIDs ?? []).filter { $0 != labelID }
                }
            }
        case .delete(let ids):
            try? await store.remove(ids)
        }
        bump()
    }

    // MARK: Local updates

    /// Applies an action to the cache right away so the UI (and offline use) reflect it.
    func applyLocally(_ id: String, _ change: @escaping (inout MessageMetadata) -> Void) async {
        try? await store.update(id, change)
        bump()
    }

    func removeLocally(_ ids: [String]) async {
        try? await store.remove(ids)
        bump()
    }

    private func bump() { revision += 1 }
}

struct LatestEventResponse: Decodable {
    let eventID: String
}

/// A mailbox change that can be queued while offline.
enum MailAction: Codable, Hashable {
    case markRead(ids: [String], read: Bool)
    case label(ids: [String], labelID: String)
    case unlabel(ids: [String], labelID: String)
    case delete(ids: [String])

    /// Inbox, trash, spam, archive: a message is in exactly one folder.
    static let systemFolderIDs: Set<String> = [Mailbox.inbox.rawValue, Mailbox.trash.rawValue, Mailbox.spam.rawValue, Mailbox.archive.rawValue]

    func run(on service: MailService) async throws {
        switch self {
        case .markRead(let ids, let read): try await service.markRead(ids, read: read)
        case .label(let ids, let labelID): try await service.label(ids, labelID: labelID)
        case .unlabel(let ids, let labelID): try await service.unlabel(ids, labelID: labelID)
        case .delete(let ids): try await service.delete(ids)
        }
    }
}

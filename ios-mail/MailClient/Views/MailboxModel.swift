import Foundation
import Observation

/// A message plus the account it belongs to (the unified inbox mixes accounts).
struct MailItem: Identifiable, Hashable {
    let accountID: String
    let message: MessageMetadata

    var id: String { accountID + ":" + message.id }
}

/// What the sidebar selected.
enum MailboxSelection: Hashable {
    case system(Mailbox)
    case custom(MailLabel)
    case outbox

    var labelID: String? {
        switch self {
        case .system(let mailbox): return mailbox.rawValue
        case .custom(let label): return label.id
        case .outbox: return nil
        }
    }

    var title: String {
        switch self {
        case .system(let mailbox): return mailbox.title
        case .custom(let label): return label.name
        case .outbox: return "Outbox"
        }
    }

    var systemImage: String {
        switch self {
        case .system(let mailbox): return mailbox.systemImage
        case .custom(let label): return label.isFolder ? "folder" : "tag"
        case .outbox: return "tray.and.arrow.up"
        }
    }
}

/// List state for one mailbox across one or more accounts. Reads from each account's offline store
/// (so it works without a connection) and refreshes from the server when online.
@MainActor
@Observable
final class MailboxModel {
    let accounts: [Account]
    let selection: MailboxSelection

    private(set) var items: [MailItem] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var canLoadMore = true
    var errorMessage: String?
    var searchText = ""
    /// Search results replace the list while a search is active.
    private(set) var searchResults: [MailItem]?
    private(set) var searchUsedLocalIndexOnly = false

    private var limit = 50
    private static let pageSize = 50

    init(accounts: [Account], selection: MailboxSelection) {
        self.accounts = accounts
        self.selection = selection
    }

    var isUnified: Bool { accounts.count > 1 }
    var visibleItems: [MailItem] { searchResults ?? items }

    func account(for item: MailItem) -> Account? {
        accounts.first { $0.id == item.accountID }
    }

    /// Changes whenever any account's cache changes.
    var revision: Int { accounts.reduce(0) { $0 &+ ($1.sync?.revision ?? 0) } }

    // MARK: Loading

    func reloadFromStore() async {
        guard let labelID = selection.labelID else { return }
        var merged: [MailItem] = []
        for account in accounts {
            guard let store = account.store,
                  let messages = try? await store.messages(labelID: labelID, limit: limit) else { continue }
            merged += messages.map { MailItem(accountID: account.id, message: $0) }
        }
        items = Array(merged.sorted { $0.message.time > $1.message.time }.prefix(limit))
    }

    func refresh() async {
        guard let labelID = selection.labelID else { return }
        await reloadFromStore()
        guard NetworkMonitor.shared.isOnline else { return }
        isLoading = true
        defer { isLoading = false }
        var failure: Error?
        await withTaskGroup(of: Error?.self) { group in
            for account in accounts {
                guard let sync = account.sync else { continue }
                group.addTask { @MainActor in
                    do { try await sync.refresh(labelID: labelID); return nil } catch { return error }
                }
            }
            for await error in group where error != nil { failure = error }
        }
        errorMessage = failure?.localizedDescription
        await reloadFromStore()
    }

    func loadMore() async {
        guard let labelID = selection.labelID, canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let before = items.count
        limit += Self.pageSize
        if NetworkMonitor.shared.isOnline {
            let page = limit / Self.pageSize - 1
            for account in accounts {
                _ = try? await account.sync?.loadPage(labelID: labelID, page: page)
            }
        }
        await reloadFromStore()
        canLoadMore = items.count > before
    }

    // MARK: Search

    /// Runs operator search: the server evaluates metadata filters and keywords; the local full-text
    /// index adds matches inside downloaded message bodies (and is all that's used offline).
    func search() async {
        let query = SearchQuery(searchText)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        let online = NetworkMonitor.shared.isOnline
        var results: [String: MailItem] = [:]

        for account in accounts {
            if let store = account.store {
                let local: [MessageMetadata]
                if let fts = query.ftsQuery {
                    local = (try? await store.search(fts)) ?? []
                } else if let labelID = query.systemMailbox?.rawValue ?? selection.labelID {
                    local = (try? await store.messages(labelID: labelID, limit: 500)) ?? []
                } else {
                    local = []
                }
                for message in local where query.matches(message) {
                    let item = MailItem(accountID: account.id, message: message)
                    results[item.id] = item
                }
            }
            if online, let service = account.service {
                let labelID = query.systemMailbox?.rawValue ?? Mailbox.allMail.rawValue
                if let response = try? await service.messages(labelID: labelID, page: 0, pageSize: 100, search: query) {
                    try? await account.store?.upsert(response.messages)
                    for message in response.messages {
                        let item = MailItem(accountID: account.id, message: message)
                        results[item.id] = item
                    }
                }
            }
        }
        searchUsedLocalIndexOnly = !online
        searchResults = results.values.sorted { $0.message.time > $1.message.time }
    }

    func clearSearch() {
        searchText = ""
        searchResults = nil
    }

    // MARK: Actions

    func perform(_ swipe: AppSettings.SwipeAction, on item: MailItem) {
        guard let sync = account(for: item)?.sync else { return }
        let ids = [item.message.id]
        let action: MailAction?
        switch swipe {
        case .none: action = nil
        case .archive: action = .label(ids: ids, labelID: Mailbox.archive.rawValue)
        case .trash:
            action = selection == .system(.trash) ? .delete(ids: ids) : .label(ids: ids, labelID: Mailbox.trash.rawValue)
        case .spam: action = .label(ids: ids, labelID: Mailbox.spam.rawValue)
        case .moveToInbox: action = .label(ids: ids, labelID: Mailbox.inbox.rawValue)
        case .toggleRead: action = .markRead(ids: ids, read: item.message.isUnread)
        case .star:
            action = isStarred(item) ? .unlabel(ids: ids, labelID: Mailbox.starred.rawValue)
                                     : .label(ids: ids, labelID: Mailbox.starred.rawValue)
        }
        guard let action else { return }
        Task {
            await sync.perform(action)
            await reloadFromStore()
            if searchResults != nil { await search() }
        }
    }

    func perform(_ action: MailAction, accountID: String) {
        guard let sync = accounts.first(where: { $0.id == accountID })?.sync else { return }
        Task {
            await sync.perform(action)
            await reloadFromStore()
        }
    }

    func isStarred(_ item: MailItem) -> Bool {
        (item.message.labelIDs ?? []).contains(Mailbox.starred.rawValue)
    }

    /// Whether a swipe would take the message out of the current list.
    func removesFromList(_ swipe: AppSettings.SwipeAction) -> Bool {
        switch swipe {
        case .archive: return selection != .system(.archive)
        case .trash: return true
        case .spam: return selection != .system(.spam)
        case .moveToInbox: return selection != .system(.inbox)
        case .none, .toggleRead, .star: return false
        }
    }
}

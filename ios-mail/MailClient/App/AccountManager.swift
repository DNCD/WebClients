import Foundation
import Observation

/// One signed-in Proton account, with its own API session, offline store and sync engine.
@MainActor
@Observable
final class Account: Identifiable {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let id: String
    private(set) var email: String
    private(set) var displayName: String
    let api: APIClient
    private(set) var state: State = .loading
    private(set) var service: MailService?
    private(set) var sync: SyncEngine?
    private(set) var store: MailStore?
    /// With several accounts, notifications say which one the mail arrived in.
    var showsAccountInNotifications = false

    init(id: String, email: String, displayName: String, api: APIClient) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.api = api
    }

    /// Unlocks keys (from the network, or the cached key material when offline) and starts syncing.
    func load(settings: AppSettings) async {
        guard let passphrases = AccountVault.passphrases(for: id) else {
            state = .failed("This account needs to sign in again.")
            return
        }
        do {
            let store = try self.store ?? MailStore(accountID: id)
            self.store = store
            let service = try await MailService.load(api: api, passphrases: passphrases, store: store)
            self.service = service
            if let address = service.addresses.first {
                email = address.email
                displayName = address.displayName ?? displayName
            }
            let sync = self.sync ?? SyncEngine(account: id, service: service, store: store, settings: settings)
            sync.onNewMessages = { [weak self] messages in
                guard let self else { return }
                NotificationManager.shared.notify(accountID: self.id, accountEmail: self.email, messages: messages,
                                                  showAccount: self.showsAccountInNotifications)
            }
            self.sync = sync
            state = .ready
            await sync.start()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func tearDown() async {
        sync?.stop()
        await api.setTokens(nil)
    }
}

struct AccountSummary: Codable, Identifiable, Hashable {
    let id: String
    var email: String
    var displayName: String
}

/// Per-account secrets in the Keychain: API tokens and derived key passphrases (never passwords).
enum AccountVault {
    static func tokens(for id: String) -> SessionTokens? { Keychain.load(SessionTokens.self, for: "account.\(id).tokens") }
    static func passphrases(for id: String) -> [String: String]? { Keychain.load([String: String].self, for: "account.\(id).passphrases") }

    static func save(tokens: SessionTokens?, for id: String) {
        if let tokens { try? Keychain.save(tokens, for: "account.\(id).tokens") } else { Keychain.delete("account.\(id).tokens") }
    }

    static func save(passphrases: [String: String], for id: String) {
        try? Keychain.save(passphrases, for: "account.\(id).passphrases")
    }

    static func remove(_ id: String) {
        Keychain.delete("account.\(id).tokens")
        Keychain.delete("account.\(id).passphrases")
    }
}

/// All accounts plus the sign-in flow used to add one.
@MainActor
@Observable
final class AccountManager {
    enum LoginStep: Equatable {
        case credentials
        case twoFactor
        case mailboxPassword
    }

    private(set) var accounts: [Account] = []
    private(set) var activeAccountID: String?
    /// Non-nil while the sign-in flow is showing.
    private(set) var loginStep: LoginStep?
    private(set) var isRestoring = true
    private var restoreStarted = false
    private(set) var isBusy = false
    var errorMessage: String?

    private let settings: AppSettings
    private var pendingAPI: APIClient?
    private var pendingPassword: String?
    private var pendingPasswordMode = 1

    private static let listKey = "accounts.list"
    private static let activeKey = "accounts.active"

    init(settings: AppSettings) {
        self.settings = settings
        NotificationManager.shared.actionHandler = { [weak self] accountID, messageID, action in
            await self?.performNotificationAction(accountID: accountID, messageID: messageID, action: action)
        }
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    /// Inbox unread count across accounts, for the app badge.
    var totalUnread: Int {
        readyAccounts.reduce(0) { $0 + ($1.sync?.unreadCounts[Mailbox.inbox.rawValue] ?? 0) }
    }

    private func performNotificationAction(accountID: String, messageID: String, action: String) async {
        guard let account = account(accountID), let sync = account.sync else { return }
        if action == NotificationManager.markReadAction {
            await sync.applyLocally(messageID) { $0.unread = 0 }
            try? await sync.service.markRead([messageID])
        } else if action == NotificationManager.archiveAction {
            await sync.removeLocally([messageID])
            try? await sync.service.move([messageID], to: .archive)
        }
    }

    /// Background app refresh: restore accounts if the app was launched in the background, sync
    /// each one (which posts notifications for new mail), update the badge and reschedule.
    func backgroundRefresh() async {
        if isRestoring && accounts.isEmpty { await restore() }
        for account in readyAccounts {
            await account.sync?.syncNow()
        }
        NotificationManager.shared.setBadge(totalUnread)
        NotificationManager.scheduleBackgroundRefresh()
    }

    private func updateAccountFlags() {
        for account in accounts { account.showsAccountInNotifications = accounts.count > 1 }
    }

    var activeAccount: Account? { accounts.first { $0.id == activeAccountID } ?? accounts.first }

    var readyAccounts: [Account] { accounts.filter { $0.state == .ready } }

    /// Accounts shown in the unified inbox.
    var unifiedAccounts: [Account] {
        settings.unifiedInbox && readyAccounts.count > 1 ? readyAccounts : activeAccount.map { [$0] } ?? []
    }

    func restore() async {
        guard isRestoring, accounts.isEmpty, !restoreStarted else { return }
        restoreStarted = true
        let summaries = (UserDefaults.standard.data(forKey: Self.listKey))
            .flatMap { try? JSONDecoder().decode([AccountSummary].self, from: $0) } ?? []
        for summary in summaries {
            guard let tokens = AccountVault.tokens(for: summary.id) else { continue }
            let api = APIClient()
            await api.setTokens(tokens)
            await watchTokens(api, accountID: summary.id)
            accounts.append(Account(id: summary.id, email: summary.email, displayName: summary.displayName, api: api))
        }
        updateAccountFlags()
        activeAccountID = UserDefaults.standard.string(forKey: Self.activeKey) ?? accounts.first?.id
        loginStep = accounts.isEmpty ? .credentials : nil
        isRestoring = false
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await account.load(settings: self.settings) }
            }
        }
    }

    func activate(_ id: String) {
        activeAccountID = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
    }

    func beginAddingAccount() {
        errorMessage = nil
        loginStep = .credentials
    }

    func cancelLogin() {
        guard !accounts.isEmpty else { return }
        pendingAPI = nil
        pendingPassword = nil
        loginStep = nil
    }

    func signOut(_ id: String) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        await AuthService(api: account.api).logout()
        await account.tearDown()
        AccountVault.remove(id)
        MailStore.destroy(accountID: id)
        accounts.removeAll { $0.id == id }
        if activeAccountID == id { activate(accounts.first?.id ?? "") }
        saveList()
        if accounts.isEmpty { loginStep = .credentials }
    }

    /// Called when an account's refresh token stops working.
    private func sessionExpired(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        Task {
            await account.tearDown()
            AccountVault.remove(id)
            accounts.removeAll { $0.id == id }
            saveList()
            errorMessage = "The session for \(account.email) expired. Please sign in again."
            loginStep = .credentials
        }
    }

    // MARK: Sign-in flow

    func login(username: String, password: String) async {
        let api = APIClient()
        pendingAPI = api
        await run {
            switch try await AuthService(api: api).login(username: username, password: password) {
            case .needsTwoFactor(let passwordMode):
                self.pendingPassword = password
                self.pendingPasswordMode = passwordMode
                self.loginStep = .twoFactor
            case .needsMailboxPassword:
                self.loginStep = .mailboxPassword
            case .unlocked(let passphrases):
                try await self.finishLogin(passphrases)
            }
        }
    }

    func submitTwoFactor(code: String) async {
        guard let api = pendingAPI else { return }
        await run {
            let auth = AuthService(api: api)
            try await auth.submitTwoFactor(code: code)
            if self.pendingPasswordMode == 2 {
                self.pendingPassword = nil
                self.loginStep = .mailboxPassword
            } else if let password = self.pendingPassword, case .unlocked(let passphrases) = try await auth.unlock(password: password) {
                try await self.finishLogin(passphrases)
            }
        }
    }

    func submitMailboxPassword(_ password: String) async {
        guard let api = pendingAPI else { return }
        await run {
            if case .unlocked(let passphrases) = try await AuthService(api: api).unlock(password: password) {
                try await self.finishLogin(passphrases)
            }
        }
    }

    private func finishLogin(_ passphrases: [String: String]) async throws {
        guard let api = pendingAPI, let tokens = await api.tokens else { return }
        let user: UserResponse = try await api.send(.get("core/v4/users"))
        let id = user.user.id

        if let existing = accounts.first(where: { $0.id == id }) {
            // Signing in again to an account we already have: replace its session.
            await existing.tearDown()
            accounts.removeAll { $0.id == id }
        }
        AccountVault.save(tokens: tokens, for: id)
        AccountVault.save(passphrases: passphrases, for: id)
        await watchTokens(api, accountID: id)

        let account = Account(id: id, email: user.user.name ?? "", displayName: user.user.displayName ?? "", api: api)
        accounts.append(account)
        activate(id)
        saveList()
        pendingAPI = nil
        pendingPassword = nil
        loginStep = nil
        await account.load(settings: settings)
        saveList()
    }

    private func watchTokens(_ api: APIClient, accountID: String) async {
        await api.setOnTokensChanged { tokens in
            AccountVault.save(tokens: tokens, for: accountID)
        }
        await api.setOnSessionExpired { [weak self] in
            Task { @MainActor in self?.sessionExpired(accountID) }
        }
    }

    private func saveList() {
        updateAccountFlags()
        let summaries = accounts.map { AccountSummary(id: $0.id, email: $0.email, displayName: $0.displayName) }
        UserDefaults.standard.set(try? JSONEncoder().encode(summaries), forKey: Self.listKey)
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

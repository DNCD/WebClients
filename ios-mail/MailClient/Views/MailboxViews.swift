import SwiftUI

struct MainView: View {
    @Environment(AccountManager.self) private var manager
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var network

    @State private var selection: MailboxSelection? = .system(.inbox)
    @State private var model: MailboxModel?
    @State private var selectedItemID: String?
    @State private var compose: ComposeView.Prefill?
    @State private var showsSettings = false

    private var notifications: NotificationManager { NotificationManager.shared }

    /// Accounts the current mailbox shows: all of them for the unified inbox, else the active one.
    private var mailboxAccounts: [Account] {
        if selection == .system(.inbox) { return manager.unifiedAccounts }
        return manager.activeAccount.map { [$0] } ?? []
    }

    private var modelKey: String {
        "\(String(describing: selection))|\(mailboxAccounts.map(\.id).joined(separator: ","))"
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, showsSettings: $showsSettings)
        } content: {
            Group {
                if selection == .outbox, let account = manager.activeAccount {
                    OutboxView(account: account)
                } else if let model {
                    MessageListView(model: model, selection: $selectedItemID)
                } else {
                    ContentUnavailableView("Loading…", systemImage: "tray")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !network.isOnline { OfflineBanner() }
            }
            .overlay(alignment: .bottomTrailing) {
                ComposeButton { compose = ComposeView.Prefill() }
                    .padding(20)
            }
        } detail: {
            if let selectedItemID, let parts = Self.split(selectedItemID), let account = manager.account(parts.accountID) {
                MessageView(account: account, messageID: parts.messageID, mailbox: selection ?? .system(.inbox),
                            onClose: { self.selectedItemID = nil }) { prefill in
                    compose = prefill
                }
                .id(selectedItemID)
            } else {
                ContentUnavailableView("No Message Selected", systemImage: "envelope.open",
                                       description: Text("Pick a message to read it."))
            }
        }
        .sheet(item: $compose) { prefill in
            if let account = manager.account(prefill.accountID ?? "") ?? manager.activeAccount {
                ComposeView(account: account, prefill: prefill)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .onChange(of: modelKey, initial: true) {
            selectedItemID = nil
            if let selection, selection != .outbox, !mailboxAccounts.isEmpty {
                model = MailboxModel(accounts: mailboxAccounts, selection: selection)
            }
        }
        .onChange(of: notifications.pendingOpen?.messageID) {
            guard let open = notifications.pendingOpen else { return }
            manager.activate(open.accountID)
            selection = .system(.inbox)
            selectedItemID = open.accountID + ":" + open.messageID
            notifications.pendingOpen = nil
        }
        .onChange(of: manager.totalUnread) { _, count in
            notifications.setBadge(count)
        }
    }

    static func split(_ id: String) -> (accountID: String, messageID: String)? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}

private struct OfflineBanner: View {
    var body: some View {
        Label("Offline — showing downloaded mail. Changes will sync when you're back online.", systemImage: "wifi.slash")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color.orange.gradient)
    }
}

struct SidebarView: View {
    @Environment(AccountManager.self) private var manager
    @Binding var selection: MailboxSelection?
    @Binding var showsSettings: Bool

    private var account: Account? { manager.activeAccount }
    private var labels: [MailLabel] { account?.sync?.labels ?? [] }

    var body: some View {
        List(selection: $selection) {
            if manager.accounts.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(manager.accounts) { account in
                                AccountChip(account: account, isActive: account.id == manager.activeAccount?.id) {
                                    withAnimation(.snappy) { manager.activate(account.id) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }

            Section {
                ForEach(Mailbox.allCases) { mailbox in
                    row(.system(mailbox), title: mailbox == .inbox && manager.unifiedAccounts.count > 1 ? "All Inboxes" : mailbox.title,
                        icon: mailbox.systemImage, tint: mailbox.tint, count: unread(mailbox.rawValue))
                }
                if let outbox = account?.sync?.outbox, !outbox.isEmpty {
                    row(.outbox, title: "Outbox", icon: "tray.and.arrow.up", tint: .orange, count: outbox.count)
                }
            }

            let folders = labels.filter(\.isFolder).sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            if !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders) { folder in
                        row(.custom(folder), title: folder.path ?? folder.name, icon: "folder.fill",
                            tint: Color(hex: folder.color) ?? .secondary, count: unread(folder.id))
                    }
                }
            }
            let tags = labels.filter { !$0.isFolder }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            if !tags.isEmpty {
                Section("Labels") {
                    ForEach(tags) { label in
                        row(.custom(label), title: label.name, icon: "tag.fill",
                            tint: Color(hex: label.color) ?? .secondary, count: unread(label.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(account?.displayName.isEmpty == false ? account!.displayName : "Mail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsSettings = true } label: {
                    if let account {
                        AvatarView(name: account.displayName, address: account.email, size: 30)
                    } else {
                        Image(systemName: "gearshape")
                    }
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private func unread(_ labelID: String) -> Int {
        let accounts = labelID == Mailbox.inbox.rawValue ? manager.unifiedAccounts : (account.map { [$0] } ?? [])
        return accounts.reduce(0) { $0 + ($1.sync?.unreadCounts[labelID] ?? 0) }
    }

    private func row(_ value: MailboxSelection, title: String, icon: String, tint: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .tag(value)
    }
}

private struct AccountChip: View {
    let account: Account
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                AvatarView(name: account.displayName, address: account.email, size: 40)
                    .overlay(Circle().stroke(isActive ? Theme.brand : .clear, lineWidth: 2.5).padding(-3))
                    .overlay(alignment: .topTrailing) {
                        let unread = account.sync?.unreadCounts[Mailbox.inbox.rawValue] ?? 0
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .background(Color.red, in: Capsule())
                                .offset(x: 6, y: -4)
                        }
                    }
                Text(account.email.split(separator: "@").first.map(String.init) ?? account.email)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(account.email)")
    }
}

struct ComposeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Theme.brandGradient, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
        .accessibilityLabel("New message")
    }
}

struct MessageListView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var model: MailboxModel
    @Binding var selection: String?
    @State private var pendingDelete: MailItem?

    var body: some View {
        List(selection: $selection) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowSeparator(.hidden)
            }
            if model.searchResults != nil {
                SearchSummary(model: model)
            }
            ForEach(model.visibleItems) { item in
                MessageRow(message: item.message,
                           accountEmail: model.isUnified ? model.account(for: item)?.email : nil)
                    .tag(item.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        swipeButton(settings.leadingSwipe, item)
                        swipeButton(settings.leadingSwipeSecondary, item)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        swipeButton(settings.trailingSwipe, item)
                        swipeButton(settings.trailingSwipeSecondary, item)
                    }
                    .onAppear {
                        if model.searchResults == nil, item.id == model.items.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
            }
            if model.isLoading || model.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.isUnified && model.selection == .system(.inbox) ? "All Inboxes" : model.selection.title)
        .searchable(text: $model.searchText, prompt: "Search — try from: has:attachment")
        .searchSuggestions {
            if model.searchText.isEmpty {
                ForEach(SearchHint.all, id: \.self) { hint in
                    Label(hint.label, systemImage: hint.icon).searchCompletion(hint.token)
                }
            }
        }
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.searchText) { _, newValue in
            if newValue.isEmpty { model.clearSearch() }
        }
        .refreshable { await model.refresh() }
        .task(id: ObjectIdentifier(model)) { await model.refresh() }
        .onChange(of: model.revision) {
            Task { await model.reloadFromStore() }
        }
        .onChange(of: selection) { _, id in
            // Opening a message marks it read (MessageView); reflect it in the list right away.
            guard let id, let item = model.visibleItems.first(where: { $0.id == id }), item.message.isUnread else { return }
            model.perform(.markRead(ids: [item.message.id], read: true), accountID: item.accountID)
        }
        .confirmationDialog("Delete this message permanently?", isPresented: .init(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { model.perform(.trash, on: pendingDelete) }
                pendingDelete = nil
            }
        }
        .overlay {
            if !model.isLoading, !model.isSearching, model.visibleItems.isEmpty, model.errorMessage == nil {
                ContentUnavailableView(model.searchResults == nil ? "No Messages" : "No Results",
                                       systemImage: model.searchResults == nil ? model.selection.systemImage : "magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func swipeButton(_ action: AppSettings.SwipeAction, _ item: MailItem) -> some View {
        if action != .none {
            let permanent = action == .trash && model.selection == .system(.trash)
            Button(role: model.removesFromList(action) ? .destructive : nil) {
                if permanent && settings.confirmDelete {
                    pendingDelete = item
                } else {
                    model.perform(action, on: item)
                }
            } label: {
                Label(title(action, item), systemImage: icon(action, item))
            }
            .tint(action.tint)
        }
    }

    private func title(_ action: AppSettings.SwipeAction, _ item: MailItem) -> String {
        switch action {
        case .toggleRead: return item.message.isUnread ? "Read" : "Unread"
        case .star: return model.isStarred(item) ? "Unstar" : "Star"
        case .trash where model.selection == .system(.trash): return "Delete"
        default: return action.title
        }
    }

    private func icon(_ action: AppSettings.SwipeAction, _ item: MailItem) -> String {
        switch action {
        case .toggleRead: return item.message.isUnread ? "envelope.open.fill" : "envelope.badge.fill"
        case .star: return model.isStarred(item) ? "star.slash.fill" : "star.fill"
        default: return action.systemImage
        }
    }
}

private struct SearchSummary: View {
    let model: MailboxModel

    var body: some View {
        let count = model.searchResults?.count ?? 0
        Label {
            Text("\(count) result\(count == 1 ? "" : "s")")
                + Text(model.searchUsedLocalIndexOnly ? " · offline, searched downloaded mail" : " · includes message bodies you've downloaded")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "text.magnifyingglass")
        }
        .font(.caption)
        .listRowSeparator(.hidden)
    }
}

private struct SearchHint: Hashable {
    let label: String
    let token: String
    let icon: String

    static let all = [
        SearchHint(label: "From someone", token: "from:", icon: "person"),
        SearchHint(label: "Sent to someone", token: "to:", icon: "person.2"),
        SearchHint(label: "Subject contains", token: "subject:", icon: "textformat"),
        SearchHint(label: "Has attachments", token: "has:attachment ", icon: "paperclip"),
        SearchHint(label: "Unread", token: "is:unread ", icon: "envelope.badge"),
        SearchHint(label: "Starred", token: "is:starred ", icon: "star"),
        SearchHint(label: "Last 7 days", token: "newer_than:7d ", icon: "calendar"),
        SearchHint(label: "Before a date", token: "before:2026-01-01 ", icon: "calendar.badge.clock"),
        SearchHint(label: "Exact phrase", token: "\"", icon: "quote.opening"),
        SearchHint(label: "Exclude a word", token: "-", icon: "minus.circle"),
    ]
}

struct MessageRow: View {
    @Environment(PrivacyStore.self) private var privacy
    @Environment(AppSettings.self) private var settings
    let message: MessageMetadata
    var accountEmail: String?

    private var isStarred: Bool { message.labelIDs?.contains(Mailbox.starred.rawValue) ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if settings.showsAvatars {
                AvatarView(name: message.sender.name, address: message.sender.address, size: settings.density.avatarSize)
                    .overlay(alignment: .topLeading) { unreadDot.offset(x: -3, y: -3) }
            } else {
                unreadDot.padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: settings.density == .compact ? 1 : 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender.displayName)
                        .font(.body.weight(message.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(message.date.mailListFormat)
                        .font(.caption)
                        .foregroundStyle(message.isUnread ? Theme.brand : .secondary)
                }
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.subheadline.weight(message.isUnread ? .medium : .regular))
                    .foregroundStyle(message.isUnread ? .primary : .secondary)
                    .lineLimit(settings.previewLines)
                HStack(spacing: 6) {
                    if let accountEmail {
                        Text(accountEmail)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .lineLimit(1)
                    }
                    if let summary = privacy.summary(for: message.id), summary.total > 0 {
                        TrackerShield(summary: summary)
                    }
                    if (message.numAttachments ?? 0) > 0 {
                        Image(systemName: "paperclip")
                    }
                    if isStarred {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    if NotificationManager.shared.isVIP(message.sender.address) {
                        Image(systemName: "crown.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, settings.density.rowPadding)
    }

    @ViewBuilder
    private var unreadDot: some View {
        Circle()
            .fill(message.isUnread ? Theme.brand : .clear)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(message.isUnread ? Color(.systemBackground) : .clear, lineWidth: 2))
    }
}

struct OutboxView: View {
    let account: Account

    var body: some View {
        List {
            if let sync = account.sync {
                ForEach(sync.outbox) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.to.joined(separator: ", ")).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.subject.isEmpty ? "(No subject)" : item.subject).lineLimit(1)
                        Label(item.lastError ?? "Waiting for a connection", systemImage: item.lastError == nil ? "clock" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(item.lastError == nil ? .secondary : Color.red)
                    }
                    .swipeActions {
                        Button("Discard", role: .destructive) {
                            Task { await sync.removeFromOutbox(item.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Outbox")
        .toolbar {
            Button("Send Now") {
                Task { await account.sync?.flushOutbox() }
            }
        }
        .overlay {
            if account.sync?.outbox.isEmpty ?? true {
                ContentUnavailableView("Outbox Empty", systemImage: "tray.and.arrow.up",
                                       description: Text("Mail you send while offline waits here."))
            }
        }
    }
}

extension Mailbox {
    var tint: Color {
        switch self {
        case .inbox: return .blue
        case .drafts: return .gray
        case .sent: return .teal
        case .starred: return .yellow
        case .archive: return .indigo
        case .spam: return .orange
        case .trash: return .red
        case .allMail: return .purple
        }
    }
}

extension Color {
    /// Label colours from the API are "#RRGGBB".
    init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

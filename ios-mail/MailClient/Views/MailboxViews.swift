import SwiftUI

/// List state for one mailbox, shared by the list and the open message so actions in either stay in sync.
@MainActor
@Observable
final class MailboxModel {
    let service: MailService
    let mailbox: Mailbox

    private(set) var messages: [MessageMetadata] = []
    private(set) var total = 0
    private(set) var isLoading = false
    var errorMessage: String?
    var search = ""
    private var page = 0

    init(service: MailService, mailbox: Mailbox) {
        self.service = service
        self.mailbox = mailbox
    }

    var canLoadMore: Bool { messages.count < total }

    func reload() async { await load(page: 0) }

    func loadMore() async {
        guard canLoadMore else { return }
        await load(page: page + 1)
    }

    private func load(page: Int) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await service.messages(in: mailbox, page: page, keyword: search)
            messages = page == 0 ? response.messages : messages + response.messages
            total = response.total
            self.page = page
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setUnread(_ unread: Bool, for id: String, remote: Bool = true) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].unread = unread ? 1 : 0
        }
        guard remote else { return }
        run { try await self.service.markRead([id], read: !unread) }
    }

    func move(_ id: String, to destination: Mailbox) {
        remove(id)
        run { try await self.service.move([id], to: destination) }
    }

    func deletePermanently(_ id: String) {
        remove(id)
        run { try await self.service.delete([id]) }
    }

    private func remove(_ id: String) {
        guard messages.contains(where: { $0.id == id }) else { return }
        messages.removeAll { $0.id == id }
        total -= 1
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
                await reload()
            }
        }
    }
}

struct MainView: View {
    @Environment(SessionModel.self) private var session
    @Environment(PrivacyStore.self) private var privacy
    let service: MailService

    @State private var mailbox: Mailbox? = .inbox
    @State private var model: MailboxModel?
    @State private var selectedMessageID: String?
    @State private var compose: ComposeView.Prefill?

    var body: some View {
        NavigationSplitView {
            SidebarView(service: service, selection: $mailbox) {
                privacy.clear()
                Task { await session.signOut() }
            }
        } content: {
            if let model {
                MessageListView(model: model, selection: $selectedMessageID)
                    .overlay(alignment: .bottomTrailing) {
                        ComposeButton { compose = ComposeView.Prefill() }
                            .padding(20)
                    }
            }
        } detail: {
            if let model, let selectedMessageID {
                MessageView(model: model, messageID: selectedMessageID, onClose: { self.selectedMessageID = nil }) { prefill in
                    compose = prefill
                }
                .id(selectedMessageID)
            } else {
                ContentUnavailableView("No Message Selected", systemImage: "envelope.open",
                                       description: Text("Pick a message to read it."))
            }
        }
        .tint(Theme.brand)
        .sheet(item: $compose) { prefill in
            ComposeView(service: service, prefill: prefill)
        }
        .onChange(of: mailbox, initial: true) { _, newValue in
            selectedMessageID = nil
            model = newValue.map { MailboxModel(service: service, mailbox: $0) }
        }
    }
}

struct SidebarView: View {
    let service: MailService
    @Binding var selection: Mailbox?
    let onSignOut: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Mailbox.allCases) { mailbox in
                    Label {
                        Text(mailbox.title)
                    } icon: {
                        Image(systemName: mailbox.systemImage)
                            .foregroundStyle(mailbox.tint)
                    }
                    .tag(mailbox)
                }
            }
            Section("Protection") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tracker protection is on")
                        Text("Remote images load only through Proton's proxy; tracking links are cleaned.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.protection)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Mail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Addresses") {
                        ForEach(service.addresses) { Text($0.email) }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: onSignOut)
                } label: {
                    if let address = service.addresses.first {
                        AvatarView(name: address.displayName ?? "", address: address.email, size: 30)
                    } else {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        }
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
    @Bindable var model: MailboxModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.messages) { message in
                MessageRow(message: message)
                    .tag(message.id)
                    .swipeActions(edge: .trailing) { trailingActions(for: message) }
                    .swipeActions(edge: .leading) {
                        Button {
                            model.setUnread(!message.isUnread, for: message.id)
                        } label: {
                            Label(message.isUnread ? "Read" : "Unread", systemImage: message.isUnread ? "envelope.open.fill" : "envelope.badge.fill")
                        }
                        .tint(.blue)
                    }
                    .onAppear {
                        if message.id == model.messages.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
            }
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(model.mailbox.title)
        .searchable(text: $model.search, prompt: "Search mail")
        .onSubmit(of: .search) { Task { await model.reload() } }
        .onChange(of: model.search) { _, newValue in
            if newValue.isEmpty { Task { await model.reload() } }
        }
        .refreshable { await model.reload() }
        .task(id: ObjectIdentifier(model)) { await model.reload() }
        .onChange(of: selection) { _, id in
            // Opening a message marks it read on the server (MessageView); mirror that here.
            if let id { model.setUnread(false, for: id, remote: false) }
        }
        .overlay {
            if !model.isLoading, model.messages.isEmpty, model.errorMessage == nil {
                ContentUnavailableView(model.search.isEmpty ? "No Messages" : "No Results",
                                       systemImage: model.search.isEmpty ? model.mailbox.systemImage : "magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func trailingActions(for message: MessageMetadata) -> some View {
        if model.mailbox == .trash {
            Button(role: .destructive) { model.deletePermanently(message.id) } label: {
                Label("Delete", systemImage: "trash.slash.fill")
            }
        } else {
            Button(role: .destructive) { model.move(message.id, to: .trash) } label: {
                Label("Trash", systemImage: "trash.fill")
            }
        }
        if model.mailbox != .archive {
            Button { model.move(message.id, to: .archive) } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(.indigo)
        }
    }
}

struct MessageRow: View {
    @Environment(PrivacyStore.self) private var privacy
    let message: MessageMetadata

    private var isStarred: Bool { message.labelIDs?.contains(Mailbox.starred.rawValue) ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: message.sender.name, address: message.sender.address)
                .overlay(alignment: .topLeading) {
                    if message.isUnread {
                        Circle()
                            .fill(Theme.brand)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: -3, y: -3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
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
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let summary = privacy.summary(for: message.id), summary.total > 0 {
                        TrackerShield(summary: summary)
                    }
                    if (message.numAttachments ?? 0) > 0 {
                        Image(systemName: "paperclip")
                    }
                    if isStarred {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
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

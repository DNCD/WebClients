import SwiftUI

struct MainView: View {
    @Environment(SessionModel.self) private var session
    let service: MailService

    @State private var mailbox: Mailbox? = .inbox
    @State private var selectedMessageID: String?
    @State private var compose: ComposeView.Prefill?

    var body: some View {
        NavigationSplitView {
            List(Mailbox.allCases, selection: $mailbox) { mailbox in
                Label(mailbox.title, systemImage: mailbox.systemImage)
                    .tag(mailbox)
            }
            .navigationTitle("Mail")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(service.addresses) { Text($0.email) }
                        Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        } content: {
            if let mailbox {
                MessageListView(service: service, mailbox: mailbox, selection: $selectedMessageID)
                    .id(mailbox)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { compose = ComposeView.Prefill() } label: {
                                Image(systemName: "square.and.pencil")
                            }
                        }
                    }
            }
        } detail: {
            if let selectedMessageID {
                MessageView(service: service, messageID: selectedMessageID) { prefill in
                    compose = prefill
                }
                .id(selectedMessageID)
            } else {
                ContentUnavailableView("No Message Selected", systemImage: "envelope")
            }
        }
        .sheet(item: $compose) { prefill in
            ComposeView(service: service, prefill: prefill)
        }
    }
}

struct MessageListView: View {
    let service: MailService
    let mailbox: Mailbox
    @Binding var selection: String?

    @State private var messages: [MessageMetadata] = []
    @State private var total = 0
    @State private var page = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var search = ""

    var body: some View {
        List(selection: $selection) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(messages) { message in
                MessageRow(message: message)
                    .tag(message.id)
                    .swipeActions(edge: .trailing) {
                        if mailbox != .trash {
                            Button(role: .destructive) { perform(removing: message.id) { try await service.move([message.id], to: .trash) } } label: {
                                Label("Trash", systemImage: "trash")
                            }
                        } else {
                            Button(role: .destructive) { perform(removing: message.id) { try await service.delete([message.id]) } } label: {
                                Label("Delete", systemImage: "trash.slash")
                            }
                        }
                        if mailbox != .archive {
                            Button { perform(removing: message.id) { try await service.move([message.id], to: .archive) } } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            let read = message.isUnread
                            perform { try await service.markRead([message.id], read: read) }
                            setUnread(!read, for: message.id)
                        } label: {
                            Label(message.isUnread ? "Read" : "Unread", systemImage: message.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(.blue)
                    }
                    .onAppear {
                        if message.id == messages.last?.id, messages.count < total {
                            Task { await load(page: page + 1) }
                        }
                    }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle(mailbox.title)
        .searchable(text: $search)
        .onSubmit(of: .search) { Task { await load(page: 0) } }
        .onChange(of: search) { _, newValue in
            if newValue.isEmpty { Task { await load(page: 0) } }
        }
        .refreshable { await load(page: 0) }
        .task { await load(page: 0) }
        .onChange(of: selection) { _, id in
            // Opening a message marks it read on the server (MessageView); mirror that locally.
            if let id { setUnread(false, for: id) }
        }
        .overlay {
            if !isLoading, messages.isEmpty, errorMessage == nil {
                ContentUnavailableView(search.isEmpty ? "No Messages" : "No Results", systemImage: "tray")
            }
        }
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

    private func setUnread(_ unread: Bool, for id: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].unread = unread ? 1 : 0
        }
    }

    private func perform(removing id: String? = nil, _ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                if let id {
                    messages.removeAll { $0.id == id }
                    total -= 1
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct MessageRow: View {
    let message: MessageMetadata

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.sender.displayName)
                        .fontWeight(message.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    Text(message.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                        .font(.subheadline)
                        .lineLimit(2)
                    if (message.numAttachments ?? 0) > 0 {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI

struct ComposeView: View {
    struct Prefill: Identifiable {
        let id = UUID()
        var accountID: String?
        var to = ""
        var cc = ""
        var subject = ""
        var body = ""
        var fromAddressID: String?

        static func reply(to message: MessageDetail, content: MessageContent, accountID: String,
                          all: Bool = false, ownAddresses: [String] = []) -> Prefill {
            let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
            let date = message.date.formatted(date: .abbreviated, time: .shortened)
            var cc = ""
            if all {
                let own = Set(ownAddresses.map { $0.lowercased() })
                let others = (message.toList + (message.ccList ?? []))
                    .map(\.address)
                    .filter { !own.contains($0.lowercased()) && $0.caseInsensitiveCompare(message.sender.address) != .orderedSame }
                cc = others.joined(separator: ", ")
            }
            return Prefill(accountID: accountID,
                           to: message.sender.address,
                           cc: cc,
                           subject: subject,
                           body: "\n\nOn \(date), \(message.sender.displayName) wrote:\n\(quoted(content))",
                           fromAddressID: message.addressID)
        }

        static func forward(_ message: MessageDetail, content: MessageContent, accountID: String) -> Prefill {
            let subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
            let header = """
            ---------- Forwarded message ----------
            From: \(message.sender.displayName) <\(message.sender.address)>
            Date: \(message.date.formatted(date: .abbreviated, time: .shortened))
            Subject: \(message.subject)
            To: \(message.toList.map(\.address).joined(separator: ", "))
            """
            return Prefill(accountID: accountID, subject: subject, body: "\n\n\(header)\n\n\(plain(content))",
                           fromAddressID: message.addressID)
        }

        private static func plain(_ content: MessageContent) -> String {
            switch content {
            case .plain(let text): return text
            case .html(let html): return html.strippingHTML()
            }
        }

        private static func quoted(_ content: MessageContent) -> String {
            plain(content).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        }
    }

    let account: Account
    let prefill: Prefill

    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkMonitor.self) private var network
    @State private var contacts: ContactsService?
    @State private var from: Address?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showsCcBcc = false
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var attachments: [OutgoingAttachment] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var recentRecipients: [Recipient] = []
    @FocusState private var focused: Field?

    private enum Field { case to, cc, bcc, subject, body }

    private var service: MailService? { account.service }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ComposeRow(label: "To") {
                        recipientField($to, .to)
                        if !showsCcBcc {
                            Button {
                                withAnimation(.snappy) { showsCcBcc = true }
                            } label: {
                                Text("Cc/Bcc").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.mini)
                        }
                    }
                    suggestions(for: .to, text: $to)
                    if showsCcBcc {
                        ComposeRow(label: "Cc") { recipientField($cc, .cc) }
                        suggestions(for: .cc, text: $cc)
                        ComposeRow(label: "Bcc") { recipientField($bcc, .bcc) }
                        suggestions(for: .bcc, text: $bcc)
                    }
                    ComposeRow(label: "From") {
                        Menu {
                            ForEach(service?.sendableAddresses ?? []) { address in
                                Button(address.email) { from = address }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(from?.email ?? "Choose address").lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            }
                        }
                        Spacer()
                    }
                    ComposeRow(label: "Subject") {
                        TextField("", text: $subject)
                            .focused($focused, equals: .subject)
                            .font(.body.weight(.medium))
                    }
                    ComposeAttachments(attachments: $attachments)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider().padding(.leading, 16)
                    TextField("Write your message…", text: $messageBody, axis: .vertical)
                        .focused($focused, equals: .body)
                        .lineLimit(12...)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 16)
                    }

                    Label(network.isOnline
                          ? "End-to-end encrypted to Proton recipients. Others receive it over TLS."
                          : "You're offline. The message will wait in the Outbox and send when you reconnect.",
                          systemImage: network.isOnline ? "lock.fill" : "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(network.isOnline ? Color.secondary : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(subject.isEmpty ? "New Message" : subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button {
                            Task { await send() }
                        } label: {
                            Image(systemName: network.isOnline ? "arrow.up.circle.fill" : "tray.and.arrow.up.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, canSend ? Theme.brand : Color(.systemGray3))
                        }
                        .disabled(!canSend)
                        .accessibilityLabel(network.isOnline ? "Send" : "Queue in Outbox")
                    }
                }
            }
            .interactiveDismissDisabled(isSending || !messageBody.isEmpty || !attachments.isEmpty)
            .task {
                guard contacts == nil, let store = account.store else { return }
                let service = ContactsService(api: account.api, store: store)
                contacts = service
                await service.load()
                if let recent = try? await store.messages(labelID: Mailbox.allMail.rawValue, limit: 300) {
                    recentRecipients = recent.flatMap { [$0.sender] + $0.toList }
                }
            }
            .onAppear {
                let addresses = service?.sendableAddresses ?? []
                from = addresses.first { $0.id == prefill.fromAddressID } ?? addresses.first
                to = prefill.to
                cc = prefill.cc
                showsCcBcc = !prefill.cc.isEmpty
                subject = prefill.subject
                messageBody = prefill.body
                focused = prefill.to.isEmpty ? .to : .body
            }
        }
    }

    private var canSend: Bool { from != nil && !Self.emails(to).isEmpty && attachments.reduce(0) { $0 + $1.data.count } <= ComposeAttachments.maxTotalBytes }

    private func recipientField(_ text: Binding<String>, _ field: Field) -> some View {
        TextField("", text: text)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: field)
    }

    /// Autocomplete for the token being typed in a recipient field.
    @ViewBuilder
    private func suggestions(for field: Field, text: Binding<String>) -> some View {
        if focused == field, let contacts {
            let current = text.wrappedValue.split(whereSeparator: { $0 == "," || $0 == ";" }).last.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            let matches = current.contains("@") && current.contains(".") ? [] : contacts.suggestions(for: current, recent: recentRecipients)
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(matches) { suggestion in
                        Button {
                            text.wrappedValue = Self.replacingLastToken(in: text.wrappedValue, with: suggestion.email)
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: suggestion.name, address: suggestion.email, size: 28)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(suggestion.name.isEmpty ? suggestion.email : suggestion.name).font(.subheadline)
                                    if !suggestion.name.isEmpty {
                                        Text(suggestion.email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: suggestion.source == .proton ? "lock.shield" : suggestion.source == .device ? "person.crop.circle" : "clock")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if contacts.deviceAccess == .notDetermined {
                        Button("Include contacts from this iPhone") {
                            Task { await contacts.requestDeviceAccess() }
                        }
                        .font(.caption)
                        .padding(8)
                    }
                }
                .background(Color(.secondarySystemBackground))
            }
        }
    }

    static func replacingLastToken(in text: String, with email: String) -> String {
        var tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        if !tokens.isEmpty { tokens.removeLast() }
        tokens.append(email)
        return tokens.joined(separator: ", ") + ", "
    }

    private func send() async {
        guard let from, let sync = account.sync else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let item = OutboxItem(fromAddressID: from.id,
                              to: Self.emails(to),
                              cc: Self.emails(cc),
                              bcc: Self.emails(bcc),
                              subject: subject,
                              body: messageBody,
                              attachments: attachments)
        do {
            try await sync.send(item)
            dismiss()
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
        }
    }

    static func emails(_ field: String) -> [String] {
        field.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init)
            .filter { $0.contains("@") }
    }
}

private struct ComposeRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label + ":")
                    .foregroundStyle(.secondary)
                content
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().padding(.leading, 16)
        }
    }
}

extension String {
    /// Rough HTML-to-text conversion for quoting replies and indexing.
    func strippingHTML() -> String {
        var text = replacingOccurrences(of: "<br\\s*/?>|</p>|</div>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<style[\\s\\S]*?</style>|<script[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

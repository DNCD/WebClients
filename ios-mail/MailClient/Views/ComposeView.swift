import SwiftUI

struct ComposeView: View {
    struct Prefill: Identifiable {
        let id = UUID()
        var to = ""
        var subject = ""
        var body = ""
        var fromAddressID: String?

        static func reply(to message: MessageDetail, content: MessageContent) -> Prefill {
            let original: String
            switch content {
            case .plain(let text): original = text
            case .html(let html): original = html.strippingHTML()
            }
            let quoted = original.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
            let date = message.date.formatted(date: .abbreviated, time: .shortened)
            return Prefill(to: message.sender.address,
                           subject: subject,
                           body: "\n\nOn \(date), \(message.sender.displayName) wrote:\n\(quoted)",
                           fromAddressID: message.addressID)
        }
    }

    let service: MailService
    let prefill: Prefill

    @Environment(\.dismiss) private var dismiss
    @State private var from: Address?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var showsCcBcc = false
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case to, cc, bcc, subject, body }

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
                    if showsCcBcc {
                        ComposeRow(label: "Cc") { recipientField($cc, .cc) }
                        ComposeRow(label: "Bcc") { recipientField($bcc, .bcc) }
                    }
                    ComposeRow(label: "From") {
                        Menu {
                            ForEach(service.sendableAddresses) { address in
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

                    Label("End-to-end encrypted to Proton recipients. Others receive it over TLS.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, canSend ? Theme.brand : Color(.systemGray3))
                        }
                        .disabled(!canSend)
                        .accessibilityLabel("Send")
                    }
                }
            }
            .interactiveDismissDisabled(isSending || !messageBody.isEmpty)
            .onAppear {
                from = service.sendableAddresses.first { $0.id == prefill.fromAddressID } ?? service.sendableAddresses.first
                to = prefill.to
                subject = prefill.subject
                messageBody = prefill.body
                focused = prefill.to.isEmpty ? .to : .body
            }
        }
    }

    private var canSend: Bool { from != nil && !Self.emails(to).isEmpty }

    private func recipientField(_ text: Binding<String>, _ field: Field) -> some View {
        TextField("", text: text)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: field)
    }

    private func send() async {
        guard let from else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await service.send(.init(from: from,
                                         to: Self.emails(to),
                                         cc: Self.emails(cc),
                                         bcc: Self.emails(bcc),
                                         subject: subject,
                                         body: messageBody))
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
    /// Rough HTML-to-text conversion for quoting replies.
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

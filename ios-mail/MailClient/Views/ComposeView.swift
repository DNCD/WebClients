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
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("From", selection: $from) {
                        ForEach(service.sendableAddresses) { address in
                            Text(address.email).tag(Optional(address))
                        }
                    }
                    RecipientField(title: "To", text: $to)
                    RecipientField(title: "Cc", text: $cc)
                    RecipientField(title: "Bcc", text: $bcc)
                    TextField("Subject", text: $subject)
                }
                Section {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 240)
                } footer: {
                    Text("Mail to Proton addresses is end-to-end encrypted. Other recipients receive it unencrypted over TLS.")
                }
                ErrorSection(message: errorMessage)
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(from == nil || Self.emails(to).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isSending)
            .onAppear {
                from = service.sendableAddresses.first { $0.id == prefill.fromAddressID } ?? service.sendableAddresses.first
                to = prefill.to
                subject = prefill.subject
                messageBody = prefill.body
            }
        }
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
            errorMessage = error.localizedDescription
        }
    }

    static func emails(_ field: String) -> [String] {
        field.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init)
            .filter { $0.contains("@") }
    }
}

private struct RecipientField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text, prompt: Text("\(title): name@example.com"))
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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

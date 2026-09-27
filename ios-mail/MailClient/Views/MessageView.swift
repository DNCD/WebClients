import SwiftUI
import WebKit

struct MessageView: View {
    let service: MailService
    let messageID: String
    let onReply: (ComposeView.Prefill) -> Void

    @State private var message: MessageDetail?
    @State private var content: MessageContent?
    @State private var errorMessage: String?
    @State private var loadRemoteContent = false

    var body: some View {
        Group {
            if let message, let content {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(message)
                        Divider()
                        switch content {
                        case .plain(let text):
                            Text(text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .html(let html):
                            if !loadRemoteContent {
                                Button {
                                    loadRemoteContent = true
                                } label: {
                                    Label("Remote content blocked. Load it", systemImage: "eye.slash")
                                        .font(.footnote)
                                }
                            }
                            HTMLView(html: html, allowRemoteContent: loadRemoteContent)
                                .frame(minHeight: 400)
                        }
                        if let attachments = message.attachments, !attachments.isEmpty {
                            Divider()
                            ForEach(attachments) { attachment in
                                Label("\(attachment.name) (\(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)))",
                                      systemImage: "paperclip")
                                    .font(.footnote)
                            }
                            Text("Attachments can't be opened in this version.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { onReply(.reply(to: message, content: content)) } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Couldn't Open Message", systemImage: "lock.trianglebadge.exclamationmark", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func header(_ message: MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                .font(.title3.bold())
            Text("From: \(message.sender.displayName) <\(message.sender.address)>")
                .font(.subheadline)
            Text("To: \(message.toList.map(\.displayName).joined(separator: ", "))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(message.date, format: .dateTime)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            let detail = try await service.message(id: messageID)
            content = try service.decryptBody(of: detail)
            message = detail
            try? await service.markRead([messageID])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Renders HTML mail with JavaScript disabled and, unless allowed, every remote load blocked
/// (tracking pixels, remote CSS). Tapped links open in Safari.
struct HTMLView: UIViewRepresentable {
    let html: String
    let allowRemoteContent: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = Coordinator.Loaded(html: html, allowRemoteContent: allowRemoteContent)
        guard context.coordinator.loaded != request else { return }
        context.coordinator.loaded = request
        let document = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" + html
        Task { @MainActor in
            webView.configuration.userContentController.removeAllContentRuleLists()
            if !allowRemoteContent, let rules = await Self.blockRemoteContentRules() {
                webView.configuration.userContentController.add(rules)
            }
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    private static let rulesJSON = """
    [
      {"trigger": {"url-filter": ".*", "resource-type": ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    @MainActor
    private static func blockRemoteContentRules() async -> WKContentRuleList? {
        try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-remote", encodedContentRuleList: rulesJSON)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Loaded: Equatable {
            let html: String
            let allowRemoteContent: Bool
        }

        var loaded: Loaded?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                _ = await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

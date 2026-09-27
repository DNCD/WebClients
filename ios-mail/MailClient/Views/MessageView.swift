import SwiftUI
import WebKit

struct MessageView: View {
    @Environment(PrivacyStore.self) private var privacy
    @Environment(AppSettings.self) private var settings
    let account: Account
    let messageID: String
    let mailbox: MailboxSelection
    let onClose: () -> Void
    let onReply: (ComposeView.Prefill) -> Void

    private enum DisplayBody {
        case plain(AttributedString)
        case html(String)
    }

    @State private var message: MessageDetail?
    @State private var content: MessageContent?
    @State private var display: DisplayBody?
    @State private var report = PrivacyReport()
    @State private var errorMessage: String?
    @State private var loadRemoteContent = false
    @State private var showsReport = false
    @State private var showsAddContact = false
    @State private var htmlHeight: CGFloat = 120
    @State private var imageLoader: ProxyImageLoader?
    @State private var metadata: MessageMetadata?

    private var notifications: NotificationManager { NotificationManager.shared }

    var body: some View {
        Group {
            if let message, let display, let service = account.service {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        MessageHeader(message: message, isVIP: notifications.isVIP(message.sender.address))
                        PrivacyBanner(report: report,
                                      imagesHidden: report.remoteImageCount > 0 && !loadRemoteContent,
                                      onShowDetails: { showsReport = true },
                                      onLoadImages: { loadRemoteContent = true })
                        bodyView(display)
                        if let attachments = message.attachments, !attachments.isEmpty {
                            AttachmentsSection(attachments: attachments, message: message, service: service)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .toolbar { toolbar(message) }
                .sheet(isPresented: $showsReport) {
                    PrivacyReportView(report: report)
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showsAddContact) {
                    NewContactView(name: message.sender.name, email: message.sender.address)
                }
            } else if let errorMessage {
                ContentUnavailableView("Couldn't Open Message", systemImage: "lock.trianglebadge.exclamationmark",
                                       description: Text(errorMessage))
            } else {
                ProgressView("Decrypting…")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func bodyView(_ display: DisplayBody) -> some View {
        switch display {
        case .plain(let text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        case .html(let html):
            if let imageLoader {
                HTMLView(html: html, allowRemoteContent: loadRemoteContent, loader: imageLoader, height: $htmlHeight)
                    .frame(height: htmlHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
        }
    }

    private func perform(_ action: MailAction, close: Bool) {
        Task { await account.sync?.perform(action) }
        if close { onClose() }
    }

    @ToolbarContentBuilder
    private func toolbar(_ message: MessageDetail) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let content { onReply(.reply(to: message, content: content, accountID: account.id)) }
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Menu {
                Section {
                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                        if let content { onReply(.reply(to: message, content: content, accountID: account.id, all: true, ownAddresses: account.service?.addresses.map(\.email) ?? [])) }
                    }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") {
                        if let content { onReply(.forward(message, content: content, accountID: account.id)) }
                    }
                }
                Section {
                    Button("Mark as Unread", systemImage: "envelope.badge") {
                        perform(.markRead(ids: [messageID], read: false), close: true)
                    }
                    let starred = metadata?.labelIDs?.contains(Mailbox.starred.rawValue) ?? false
                    Button(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star") {
                        perform(starred ? .unlabel(ids: [messageID], labelID: Mailbox.starred.rawValue)
                                        : .label(ids: [messageID], labelID: Mailbox.starred.rawValue), close: false)
                        metadata?.labelIDs = starred ? (metadata?.labelIDs ?? []).filter { $0 != Mailbox.starred.rawValue }
                                                     : (metadata?.labelIDs ?? []) + [Mailbox.starred.rawValue]
                    }
                    MoveMenu(labels: account.sync?.labels ?? []) { labelID in
                        perform(.label(ids: [messageID], labelID: labelID), close: true)
                    } onLabel: { labelID in
                        perform(.label(ids: [messageID], labelID: labelID), close: false)
                    }
                }
                Section {
                    Button(notifications.isVIP(message.sender.address) ? "Remove from VIPs" : "Add Sender to VIPs",
                           systemImage: "crown") {
                        notifications.toggleVIP(message.sender.address)
                    }
                    Button("Add Sender to Contacts", systemImage: "person.crop.circle.badge.plus") {
                        showsAddContact = true
                    }
                }
                Section {
                    if mailbox != .system(.archive) {
                        Button("Archive", systemImage: "archivebox") {
                            perform(.label(ids: [messageID], labelID: Mailbox.archive.rawValue), close: true)
                        }
                    }
                    Button("Move to Spam", systemImage: "xmark.octagon") {
                        perform(.label(ids: [messageID], labelID: Mailbox.spam.rawValue), close: true)
                    }
                    if mailbox == .system(.trash) {
                        Button("Delete Permanently", systemImage: "trash.slash", role: .destructive) {
                            perform(.delete(ids: [messageID]), close: true)
                        }
                    } else {
                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                            perform(.label(ids: [messageID], labelID: Mailbox.trash.rawValue), close: true)
                        }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func load() async {
        guard let service = account.service else {
            errorMessage = "This account isn't ready yet."
            return
        }
        do {
            metadata = try? await account.store?.message(id: messageID)
            let (detail, decrypted) = try await service.loadBody(id: messageID)
            content = decrypted
            imageLoader = ProxyImageLoader(api: service.api)
            loadRemoteContent = settings.loadImagesAutomatically

            var images: [RemoteImage] = []
            switch decrypted {
            case .plain(let text):
                let cleaned = LinkCleaner.cleanText(text)
                report.cleanedLinks = cleaned.cleaned
                display = .plain(Self.linkified(cleaned.text))
            case .html(let html):
                let processed = HTMLPrivacy.process(html)
                report.cleanedLinks = processed.cleanedLinks
                images = processed.remoteImages
                report.remoteImageCount = Set(images.map(\.url)).count
                display = .html(processed.html)
            }
            message = detail
            if metadata?.isUnread ?? true {
                await account.sync?.perform(.markRead(ids: [messageID], read: true))
            }
            privacy.record(report.summary, for: messageID)

            if !images.isEmpty, NetworkMonitor.shared.isOnline {
                report.isScanning = true
                report.imageTrackers = await TrackerScanner.scan(images, api: service.api)
                report.isScanning = false
                privacy.record(report.summary, for: messageID)
            } else if !images.isEmpty {
                // Offline: the proxy can't be asked, so count the pixel-shaped images.
                report.imageTrackers = images.filter(\.isLikelyPixel).map { ImageTracker(provider: TrackerScanner.pixelProvider, url: $0.url) }
                privacy.record(report.summary, for: messageID)
            }
        } catch {
            errorMessage = error.isTransientNetworkError
                ? "This message hasn't been downloaded for offline reading yet."
                : error.localizedDescription
        }
    }

    /// Makes URLs in plain-text mail tappable.
    private static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}

/// "Move to…" and "Label as…" submenus from the account's folders and labels.
private struct MoveMenu: View {
    let labels: [MailLabel]
    let onMove: (String) -> Void
    let onLabel: (String) -> Void

    var body: some View {
        Menu("Move to…", systemImage: "folder") {
            Button("Inbox", systemImage: "tray") { onMove(Mailbox.inbox.rawValue) }
            Button("Archive", systemImage: "archivebox") { onMove(Mailbox.archive.rawValue) }
            ForEach(labels.filter(\.isFolder)) { folder in
                Button(folder.path ?? folder.name, systemImage: "folder") { onMove(folder.id) }
            }
        }
        let tags = labels.filter { !$0.isFolder }
        if !tags.isEmpty {
            Menu("Label as…", systemImage: "tag") {
                ForEach(tags) { label in
                    Button(label.name, systemImage: "tag") { onLabel(label.id) }
                }
            }
        }
    }
}

private struct MessageHeader: View {
    let message: MessageDetail
    var isVIP = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: message.sender.name, address: message.sender.address, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message.sender.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if isVIP {
                            Image(systemName: "crown.fill").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(message.date.mailListFormat)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.sender.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("to \(message.toList.map(\.displayName).joined(separator: ", "))")
                                .lineLimit(1)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("From", [message.sender])
                    detailRow("To", message.toList)
                    if let cc = message.ccList, !cc.isEmpty { detailRow("Cc", cc) }
                    if let bcc = message.bccList, !bcc.isEmpty { detailRow("Bcc", bcc) }
                    HStack(alignment: .top) {
                        Text("Date").foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(message.date.formatted(date: .complete, time: .shortened))
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
            }
        }
        .card()
    }

    private func detailRow(_ title: String, _ recipients: [Recipient]) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(recipients.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: "\n"))
        }
    }
}

/// "3 trackers blocked · 2 links cleaned", plus the hidden-images prompt.
private struct PrivacyBanner: View {
    let report: PrivacyReport
    let imagesHidden: Bool
    let onShowDetails: () -> Void
    let onLoadImages: () -> Void

    private var hasFindings: Bool { report.summary.total > 0 }

    var body: some View {
        if hasFindings || report.isScanning || report.remoteImageCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onShowDetails) {
                    HStack(spacing: 10) {
                        Image(systemName: hasFindings ? "checkmark.shield.fill" : "shield")
                            .font(.title3)
                            .foregroundStyle(hasFindings ? Theme.protection : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.subheadline.weight(.semibold))
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if report.isScanning {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if imagesHidden {
                    Divider()
                    HStack {
                        Label("Images hidden to protect your privacy", systemImage: "photo.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Load", action: onLoadImages)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
            }
            .card()
        }
    }

    private var title: String {
        if report.isScanning && !hasFindings { return "Checking for trackers…" }
        var parts: [String] = []
        let trackers = report.imageTrackers.count
        let links = report.cleanedLinks.count
        if trackers > 0 { parts.append(trackers == 1 ? "1 tracker blocked" : "\(trackers) trackers blocked") }
        if links > 0 { parts.append(links == 1 ? "1 link cleaned" : "\(links) links cleaned") }
        return parts.isEmpty ? "No trackers found" : parts.joined(separator: " · ")
    }

    private var subtitle: String {
        hasFindings ? "Tap to see what was blocked" : "Remote content is loaded only through Proton's proxy"
    }
}

struct PrivacyReportView: View {
    let report: PrivacyReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(report.providers) { provider in
                        DisclosureGroup {
                            ForEach(provider.urls, id: \.self) { url in
                                Text(url).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                            }
                        } label: {
                            Label {
                                HStack {
                                    Text(provider.name)
                                    Spacer()
                                    Text("\(provider.urls.count)").foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "eye.slash.fill").foregroundStyle(Theme.protection)
                            }
                        }
                    }
                    if report.imageTrackers.isEmpty {
                        Text(report.isScanning ? "Checking…" : "No tracking images found").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Tracking images")
                } footer: {
                    Text("Tracking pixels tell senders when and where you opened a message. They are never loaded from the sender; images you choose to load go through Proton's proxy, which hides your IP address.")
                }

                Section {
                    ForEach(report.cleanedLinks, id: \.self) { link in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(string: link.cleaned)?.host() ?? link.cleaned).font(.subheadline.weight(.medium))
                            Text("Removed: " + link.removed.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if report.cleanedLinks.isEmpty {
                        Text("No tracking links found").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Cleaned links")
                } footer: {
                    Text("Tracking parameters such as utm_source are removed from links before you open them.")
                }
            }
            .navigationTitle("Privacy Protection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Renders message HTML with JavaScript off. Direct http(s) loads are always blocked; images arrive
/// only via `pm-proxy://` (see `ProxyImageLoader`). The view grows to fit its content, and tapped
/// links open in Safari.
struct HTMLView: UIViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    let loader: ProxyImageLoader
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(loader, forURLScheme: HTMLPrivacy.proxyScheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .white
        context.coordinator.observe(webView) { newHeight in
            if abs(newHeight - height) > 1 { height = newHeight }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        loader.allowsRemoteContent = allowRemoteContent
        let request = Coordinator.Loaded(html: html, allowRemoteContent: allowRemoteContent)
        guard context.coordinator.loaded != request else { return }
        context.coordinator.loaded = request
        let document = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { margin: 0; padding: 16px; font: -apple-system-body; color: #1c1c1e; background: #fff; overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100%; }
          blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid #d1d1d6; color: #555; }
        </style></head><body>\(html)</body></html>
        """
        Task { @MainActor in
            if !context.coordinator.rulesInstalled, let rules = await Self.blockDirectLoadsRules() {
                webView.configuration.userContentController.add(rules)
                context.coordinator.rulesInstalled = true
            }
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    private static let rulesJSON = """
    [{"trigger": {"url-filter": "^https?://", "resource-type": ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]},
      "action": {"type": "block"}}]
    """

    @MainActor
    private static func blockDirectLoadsRules() async -> WKContentRuleList? {
        try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-direct-loads", encodedContentRuleList: rulesJSON)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Loaded: Equatable {
            let html: String
            let allowRemoteContent: Bool
        }

        var loaded: Loaded?
        var rulesInstalled = false
        private var observation: NSKeyValueObservation?

        func observe(_ webView: WKWebView, onHeight: @escaping (CGFloat) -> Void) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { scrollView, _ in
                let height = scrollView.contentSize.height
                DispatchQueue.main.async { onHeight(height) }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                _ = await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

import ContactsUI
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Received attachments: tap to preview (Quick Look), share, or save to the Files app.
struct AttachmentsSection: View {
    let attachments: [AttachmentInfo]
    let message: MessageDetail
    let service: MailService

    @State private var downloaded: [String: URL] = [:]
    @State private var loading: Set<String> = []
    @State private var previewURL: URL?
    @State private var exportURLs: [URL]?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if attachments.count > 1 {
                    Button {
                        Task { await saveAll() }
                    } label: {
                        Label("Save All to Files", systemImage: "folder.badge.plus").font(.caption.weight(.semibold))
                    }
                }
            }
            ForEach(attachments) { attachment in
                row(attachment)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .quickLookPreview($previewURL)
        .sheet(isPresented: .init(get: { exportURLs != nil }, set: { if !$0 { exportURLs = nil } })) {
            if let exportURLs { FileExporter(urls: exportURLs) }
        }
    }

    private func row(_ attachment: AttachmentInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.icon(for: attachment.mimeType))
                .foregroundStyle(Theme.brand)
                .frame(width: 36, height: 36)
                .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.subheadline).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if loading.contains(attachment.id) {
                ProgressView()
            } else if let url = downloaded[attachment.id] {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                Button { exportURLs = [url] } label: { Image(systemName: "folder") }
                    .accessibilityLabel("Save to Files")
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                if let url = await fetch(attachment) { previewURL = url }
            }
        }
        .contextMenu {
            Button("Preview", systemImage: "eye") {
                Task { if let url = await fetch(attachment) { previewURL = url } }
            }
            Button("Save to Files", systemImage: "folder") {
                Task { if let url = await fetch(attachment) { exportURLs = [url] } }
            }
        }
    }

    private func fetch(_ attachment: AttachmentInfo) async -> URL? {
        if let url = downloaded[attachment.id] { return url }
        loading.insert(attachment.id)
        defer { loading.remove(attachment.id) }
        do {
            let url = try await service.downloadAttachment(attachment, of: message)
            downloaded[attachment.id] = url
            errorMessage = nil
            return url
        } catch {
            errorMessage = error.isTransientNetworkError ? "Connect to the internet to download attachments." : error.localizedDescription
            return nil
        }
    }

    private func saveAll() async {
        var urls: [URL] = []
        for attachment in attachments {
            if let url = await fetch(attachment) { urls.append(url) }
        }
        if !urls.isEmpty { exportURLs = urls }
    }

    static func icon(for mimeType: String) -> String {
        let type = UTType(mimeType: mimeType)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .spreadsheet) == true { return "tablecells" }
        if type?.conforms(to: .presentation) == true { return "rectangle.on.rectangle" }
        return "doc"
    }
}

/// "Save to Files" (document picker in export mode).
struct FileExporter: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

/// iOS "New Contact" card prefilled with the sender.
struct NewContactView: UIViewControllerRepresentable {
    let name: String
    let email: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = CNMutableContact()
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? ""
        contact.familyName = parts.count > 1 ? parts[1] : ""
        contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        let controller = CNContactViewController(forNewContact: contact)
        controller.contactStore = CNContactStore()
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}

/// Composer attachment strip with pickers for Files and Photos.
struct ComposeAttachments: View {
    @Binding var attachments: [OutgoingAttachment]
    @State private var showsFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var errorMessage: String?

    /// Proton's per-message attachment limit is 25 MB.
    static let maxTotalBytes = 25 * 1024 * 1024

    private var totalBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    Button("Choose from Files", systemImage: "folder") { showsFileImporter = true }
                } label: {
                    Label("Attach", systemImage: "paperclip")
                        .font(.subheadline.weight(.medium))
                } primaryAction: {
                    showsFileImporter = true
                }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                if !attachments.isEmpty {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(totalBytes > Self.maxTotalBytes ? .red : .secondary)
                }
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { file in
                            HStack(spacing: 6) {
                                Image(systemName: AttachmentsSection.icon(for: file.mimeType))
                                Text(file.filename).lineLimit(1).frame(maxWidth: 140)
                                Button {
                                    attachments.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("Remove \(file.filename)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { add(fileAt: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: photoItems) { _, items in
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first ?? .jpeg
                    let name = "Photo-\(attachments.count + 1).\(type.preferredFilenameExtension ?? "jpg")"
                    append(OutgoingAttachment(filename: name, mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data))
                }
                photoItems = []
            }
        }
    }

    private func add(fileAt url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)
        append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data))
    }

    private func append(_ file: OutgoingAttachment) {
        guard totalBytes + file.data.count <= Self.maxTotalBytes else {
            errorMessage = "Attachments are limited to 25 MB per message."
            return
        }
        errorMessage = nil
        attachments.append(file)
    }
}

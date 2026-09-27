import SwiftUI

/// Server-side filters, like Settings → Filters on the web: they run on Proton's servers for every
/// incoming message, on all devices.
struct FiltersView: View {
    let service: MailService

    @State private var filters: [MailFilter] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsEditor = false

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
            }
            Section {
                ForEach(filters) { filter in
                    Toggle(isOn: Binding(get: { filter.isEnabled }, set: { enabled in toggle(filter, enabled) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filter.name)
                            if let sieve = filter.sieve {
                                Text(Self.summary(of: sieve))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .onDelete(perform: delete)
            } footer: {
                Text("Filters run on Proton's servers as mail arrives, so they apply on every device. Advanced (Sieve) filters made on the web show here too.")
            }
        }
        .navigationTitle("Filters & Rules")
        .overlay {
            if isLoading && filters.isEmpty {
                ProgressView()
            } else if !isLoading && filters.isEmpty && errorMessage == nil {
                ContentUnavailableView("No Filters", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Create rules to sort, label or mark mail automatically."))
            }
        }
        .toolbar {
            Button { showsEditor = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("New Filter")
        }
        .sheet(isPresented: $showsEditor) {
            FilterEditor(service: service) { created in
                filters.append(created)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            filters = try await service.filters()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ filter: MailFilter, _ enabled: Bool) {
        Task {
            do {
                try await service.setFilter(filter.id, enabled: enabled)
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { filters[$0] }
        filters.remove(atOffsets: offsets)
        Task {
            for filter in doomed {
                do { try await service.deleteFilter(filter.id) } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    /// Pulls the human-readable parts out of generated Sieve for the list subtitle.
    static func summary(of sieve: String) -> String {
        var parts: [String] = []
        if sieve.contains("\"From\"") { parts.append("sender") }
        if sieve.contains("\"To\"") { parts.append("recipient") }
        if sieve.contains("\"Subject\"") { parts.append("subject") }
        if sieve.contains("X-Attached") { parts.append("attachments") }
        var actions: [String] = []
        if sieve.contains("fileinto") { actions.append("move/label") }
        if sieve.contains("\\\\Seen") { actions.append("mark read") }
        if sieve.contains("\\\\Flagged") { actions.append("star") }
        if parts.isEmpty && actions.isEmpty { return "Custom Sieve filter" }
        return "If " + parts.joined(separator: ", ") + " → " + actions.joined(separator: ", ")
    }
}

private struct FilterEditor: View {
    let service: MailService
    let onCreate: (MailFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var filter = SimpleFilter()
    @State private var labels: [MailLabel] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showsSieve = false

    private struct SystemFolder: Hashable {
        let name: String
        let sieve: String
    }

    private static let systemFolders = [
        SystemFolder(name: "Inbox", sieve: "inbox"), SystemFolder(name: "Archive", sieve: "archive"),
        SystemFolder(name: "Spam", sieve: "spam"), SystemFolder(name: "Trash", sieve: "trash"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Filter name", text: $filter.name)
                }

                Section {
                    Picker("Match", selection: $filter.matching) {
                        ForEach(SimpleFilter.Operator.allCases) { Text($0.title).tag($0) }
                    }
                    ForEach($filter.conditions) { $condition in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Picker("If", selection: $condition.type) {
                                    ForEach(SimpleFilter.ConditionType.allCases) { Text($0.title).tag($0) }
                                }
                                .labelsHidden()
                                if condition.type != .attachments {
                                    Picker("Comparator", selection: $condition.comparator) {
                                        ForEach(SimpleFilter.Comparator.allCases) { Text($0.title).tag($0) }
                                    }
                                    .labelsHidden()
                                }
                            }
                            if condition.type == .attachments {
                                Picker("Attachments", selection: $condition.hasAttachments) {
                                    Text("has attachments").tag(true)
                                    Text("has no attachments").tag(false)
                                }
                                .pickerStyle(.segmented)
                            } else {
                                TextField(condition.type == .subject ? "Text" : "name@example.com or domain", text: $condition.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { filter.conditions.remove(atOffsets: $0) }
                    Button("Add Condition", systemImage: "plus.circle") {
                        filter.conditions.append(SimpleFilter.Condition())
                    }
                } header: {
                    Text("Conditions")
                }

                Section("Actions") {
                    Picker("Move to", selection: $filter.moveTo) {
                        Text("Don't move").tag(String?.none)
                        ForEach(Self.systemFolders, id: \.sieve) { folder in
                            Text(folder.name).tag(Optional(folder.sieve))
                        }
                        ForEach(labels.filter(\.isFolder)) { folder in
                            Text(folder.path ?? folder.name).tag(Optional(folder.path ?? folder.name))
                        }
                    }
                    let tags = labels.filter { !$0.isFolder }
                    if !tags.isEmpty {
                        NavigationLink {
                            LabelPicker(labels: tags, selection: $filter.labels)
                        } label: {
                            LabeledContent("Apply labels", value: filter.labels.isEmpty ? "None" : filter.labels.joined(separator: ", "))
                        }
                    }
                    Toggle("Mark as read", isOn: $filter.markRead)
                    Toggle("Star", isOn: $filter.star)
                }

                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }

                Section {
                    DisclosureGroup("Sieve preview", isExpanded: $showsSieve) {
                        Text(filter.sieve).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("The rule is checked by Proton's server before it's saved.")
                }
            }
            .navigationTitle("New Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(!filter.isValid)
                    }
                }
            }
            .task {
                labels = (try? await service.store.labels()) ?? []
                if labels.isEmpty { labels = (try? await service.labels()) ?? [] }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let created = try await service.createFilter(filter)
            onCreate(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LabelPicker: View {
    let labels: [MailLabel]
    @Binding var selection: [String]

    var body: some View {
        List(labels) { label in
            let name = label.path ?? label.name
            Button {
                if let index = selection.firstIndex(of: name) { selection.remove(at: index) } else { selection.append(name) }
            } label: {
                HStack {
                    Label(label.name, systemImage: "tag.fill").foregroundStyle(Color(hex: label.color) ?? .primary)
                    Spacer()
                    if selection.contains(name) { Image(systemName: "checkmark").foregroundStyle(Theme.brand) }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Labels")
    }
}

struct NotificationSettingsView: View {
    @Environment(AccountManager.self) private var manager
    @State private var newVIP = ""

    var body: some View {
        @Bindable var notifications = NotificationManager.shared
        Form {
            if notifications.authorization != .authorized && notifications.authorization != .provisional {
                Section {
                    Button("Allow Notifications", systemImage: "bell.badge") {
                        Task { await notifications.requestAuthorization() }
                    }
                } footer: {
                    Text(notifications.authorization == .denied
                         ? "Notifications are turned off for this app in iOS Settings."
                         : "Get alerted about new mail.")
                }
            }
            Section {
                Toggle("New Mail Notifications", isOn: $notifications.enabled)
                Picker("Notify For", selection: $notifications.scope) {
                    ForEach(NotificationManager.Scope.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Sender and Subject", isOn: $notifications.showPreviews)
            } footer: {
                Text("The app checks for mail while open and when iOS lets it refresh in the background, typically every 15 minutes or more. Instant push needs Proton's push service, which isn't available to this app.")
            }

            if notifications.scope == .inboxAndFolders, let labels = manager.activeAccount?.sync?.labels {
                Section("Folders") {
                    ForEach(labels.filter(\.isFolder)) { folder in
                        Toggle(folder.path ?? folder.name, isOn: Binding(
                            get: { notifications.folderIDs.contains(folder.id) },
                            set: { on in
                                if on { notifications.folderIDs.insert(folder.id) } else { notifications.folderIDs.remove(folder.id) }
                            }))
                    }
                }
            }

            Section {
                ForEach(notifications.vipSenders, id: \.self) { sender in
                    Label(sender, systemImage: "crown.fill")
                }
                .onDelete { notifications.vipSenders.remove(atOffsets: $0) }
                HStack {
                    TextField("Add VIP email", text: $newVIP)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        notifications.toggleVIP(newVIP.trimmingCharacters(in: .whitespaces))
                        newVIP = ""
                    }
                    .disabled(!newVIP.contains("@"))
                }
            } header: {
                Text("VIP Senders")
            } footer: {
                Text("VIPs are marked with a crown. Choose \"VIP senders only\" above to be notified just for them.")
            }

            Section("Quiet Hours") {
                Toggle("Silence Notifications", isOn: $notifications.quietHoursEnabled)
                if notifications.quietHoursEnabled {
                    Picker("From", selection: $notifications.quietStartHour) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                    }
                    Picker("Until", selection: $notifications.quietEndHour) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountManager.self) private var accounts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(accounts.accounts) { account in
                        HStack(spacing: 12) {
                            AvatarView(name: account.displayName, address: account.email, size: 34)
                            VStack(alignment: .leading) {
                                Text(account.displayName.isEmpty ? account.email : account.displayName)
                                Text(account.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if account.id == accounts.activeAccountID {
                                Image(systemName: "checkmark").foregroundStyle(Theme.brand)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { accounts.activate(account.id) }
                        .swipeActions {
                            Button("Sign Out", role: .destructive) {
                                Task { await accounts.signOut(account.id) }
                            }
                        }
                    }
                    Button {
                        dismiss()
                        accounts.beginAddingAccount()
                    } label: {
                        Label("Add Account", systemImage: "person.crop.circle.badge.plus")
                    }
                    if accounts.accounts.count > 1 {
                        Toggle("Unified Inbox", isOn: $settings.unifiedInbox)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { appearance in
                            Label(appearance.title, systemImage: appearance.systemImage).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Inbox Layout") {
                    Picker("Density", selection: $settings.density) {
                        ForEach(AppSettings.Density.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Show Avatars", isOn: $settings.showsAvatars)
                    Stepper("Subject Lines: \(settings.previewLines)", value: $settings.previewLines, in: 1...3)
                    MessageRowPreview()
                }

                Section {
                    SwipePicker(title: "Swipe Right", selection: $settings.leadingSwipe)
                    SwipePicker(title: "Swipe Right (second)", selection: $settings.leadingSwipeSecondary)
                    SwipePicker(title: "Swipe Left", selection: $settings.trailingSwipe)
                    SwipePicker(title: "Swipe Left (second)", selection: $settings.trailingSwipeSecondary)
                    Toggle("Confirm Before Deleting", isOn: $settings.confirmDelete)
                } header: {
                    Text("Swipe Actions")
                } footer: {
                    Text("A full swipe runs the first action.")
                }

                Section {
                    Toggle("Load Images Automatically", isOn: $settings.loadImagesAutomatically)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Images always load through Proton's proxy, and known trackers stay blocked either way.")
                }

                Section {
                    Picker("Keep Mail Offline", selection: $settings.offlineDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    if let account = accounts.activeAccount {
                        OfflineStatusRow(account: account)
                    }
                } header: {
                    Text("Offline & Search")
                } footer: {
                    Text("Messages from this period are downloaded and decrypted on this device, so you can read them offline and search their full text.")
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    if let account = accounts.activeAccount, let service = account.service {
                        NavigationLink {
                            FiltersView(service: service)
                        } label: {
                            Label("Filters & Rules", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SwipePicker: View {
    let title: String
    @Binding var selection: AppSettings.SwipeAction

    var body: some View {
        Picker(selection: $selection) {
            ForEach(AppSettings.SwipeAction.allCases) { action in
                Label(action.title, systemImage: action.systemImage).tag(action)
            }
        } label: {
            Text(title)
        }
    }
}

/// Live preview of the list row with the current layout settings.
private struct MessageRowPreview: View {
    var body: some View {
        MessageRow(message: MessageMetadata(
            id: "preview", conversationID: nil, addressID: "", subject: "Your weekly summary is ready to read",
            sender: Recipient(name: "Alex Rivera", address: "alex@example.com"),
            toList: [], ccList: nil, time: Date().timeIntervalSince1970 - 3600, size: nil, unread: 1,
            numAttachments: 1, flags: nil, labelIDs: [Mailbox.inbox.rawValue, Mailbox.starred.rawValue]))
        .allowsHitTesting(false)
    }
}

private struct OfflineStatusRow: View {
    let account: Account

    var body: some View {
        LabeledContent("Downloaded") {
            if let sync = account.sync {
                if sync.isDownloadingBodies {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(sync.cachedBodyCount)")
                    }
                } else {
                    Text("\(sync.cachedBodyCount) messages")
                }
            } else {
                Text("—")
            }
        }
    }
}

extension AppSettings.Appearance {
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

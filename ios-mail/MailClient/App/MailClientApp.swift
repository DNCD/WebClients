import SwiftUI

@main
struct MailClientApp: App {
    @State private var settings: AppSettings
    @State private var manager: AccountManager
    @State private var privacy = PrivacyStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Crypto.setUp()
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _manager = State(initialValue: AccountManager(settings: settings))
        NotificationManager.shared.setUp()
    }

    var body: some Scene {
        let accounts = manager
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(manager)
                .environment(privacy)
                .environment(NetworkMonitor.shared)
                .preferredColorScheme(settings.appearance.colorScheme)
                .task { await manager.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                NotificationManager.scheduleBackgroundRefresh()
            case .active:
                Task { for account in manager.readyAccounts { await account.sync?.syncNow() } }
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(NotificationManager.refreshTaskID)) {
            await accounts.backgroundRefresh()
        }
    }
}

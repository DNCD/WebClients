import SwiftUI

@main
struct MailClientApp: App {
    @State private var session = SessionModel()
    @State private var privacy = PrivacyStore()

    init() {
        Crypto.setUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(privacy)
                .task { await session.restore() }
        }
    }
}

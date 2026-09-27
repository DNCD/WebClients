import SwiftUI

@main
struct MailClientApp: App {
    @State private var session = SessionModel()

    init() {
        Crypto.setUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.restore() }
        }
    }
}

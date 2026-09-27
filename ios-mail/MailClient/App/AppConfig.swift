import Foundation

enum AppConfig {
    static let apiBaseURL = URL(string: "https://mail.proton.me/api")!

    /// `x-pm-appversion` header, set via the `PM_APP_VERSION` build setting in `project.yml`.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "PMAppVersion") as? String ?? "ios-mailclient@0.1.0"
}

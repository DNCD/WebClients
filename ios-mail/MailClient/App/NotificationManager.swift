import BackgroundTasks
import Foundation
import Observation
import UIKit
import UserNotifications

/// Local notifications for new mail, driven by the sync engine's event loop (in the foreground and
/// during background app refresh). Rules decide what notifies: inbox or chosen folders, VIP senders
/// only, quiet hours, and whether previews show sender and subject.
@MainActor
@Observable
final class NotificationManager: NSObject {
    static let shared = NotificationManager()
    nonisolated static let refreshTaskID = "com.example.mailclient.refresh"
    nonisolated static let categoryID = "NEW_MESSAGE"
    nonisolated static let markReadAction = "MARK_READ"
    nonisolated static let archiveAction = "ARCHIVE"

    enum Scope: String, CaseIterable, Identifiable {
        case inbox, inboxAndFolders, vipOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inbox: return "Inbox"
            case .inboxAndFolders: return "Inbox and chosen folders"
            case .vipOnly: return "VIP senders only"
            }
        }
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    var enabled: Bool { didSet { save() } }
    var scope: Scope { didSet { save() } }
    var folderIDs: Set<String> { didSet { save() } }
    var vipSenders: [String] { didSet { save() } }
    var showPreviews: Bool { didSet { save() } }
    var quietHoursEnabled: Bool { didSet { save() } }
    var quietStartHour: Int { didSet { save() } }
    var quietEndHour: Int { didSet { save() } }

    /// Set when a notification is tapped; the UI opens that message.
    var pendingOpen: (accountID: String, messageID: String)?
    /// Performs Mark Read / Archive from a notification action.
    var actionHandler: ((_ accountID: String, _ messageID: String, _ action: String) async -> Void)?

    private override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "notify.enabled") as? Bool ?? true
        scope = (defaults.string(forKey: "notify.scope")).flatMap(Scope.init) ?? .inbox
        folderIDs = Set(defaults.stringArray(forKey: "notify.folders") ?? [])
        vipSenders = defaults.stringArray(forKey: "notify.vip") ?? []
        showPreviews = defaults.object(forKey: "notify.previews") as? Bool ?? true
        quietHoursEnabled = defaults.object(forKey: "notify.quiet") as? Bool ?? false
        quietStartHour = defaults.object(forKey: "notify.quietStart") as? Int ?? 22
        quietEndHour = defaults.object(forKey: "notify.quietEnd") as? Int ?? 7
        super.init()
    }

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let markRead = UNNotificationAction(identifier: Self.markReadAction, title: "Mark as Read", options: [])
        let archive = UNNotificationAction(identifier: Self.archiveAction, title: "Archive", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [markRead, archive], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: "New message", options: [])
        ])
        Task { await refreshAuthorization() }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func isVIP(_ email: String) -> Bool {
        vipSenders.contains { $0.caseInsensitiveCompare(email) == .orderedSame }
    }

    func toggleVIP(_ email: String) {
        if isVIP(email) {
            vipSenders.removeAll { $0.caseInsensitiveCompare(email) == .orderedSame }
        } else {
            vipSenders.append(email.lowercased())
        }
    }

    /// Whether a new message should notify under the current rules.
    func shouldNotify(_ message: MessageMetadata, now: Date = Date()) -> Bool {
        guard enabled, message.isUnread else { return false }
        if quietHoursEnabled, Self.isQuiet(now: now, start: quietStartHour, end: quietEndHour) { return false }
        let labels = Set(message.labelIDs ?? [])
        switch scope {
        case .inbox:
            return labels.contains(Mailbox.inbox.rawValue)
        case .inboxAndFolders:
            return labels.contains(Mailbox.inbox.rawValue) || !labels.isDisjoint(with: folderIDs)
        case .vipOnly:
            return isVIP(message.sender.address)
        }
    }

    static func isQuiet(now: Date, start: Int, end: Int) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return start <= end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    func notify(accountID: String, accountEmail: String, messages: [MessageMetadata], showAccount: Bool) {
        guard authorization == .authorized || authorization == .provisional else { return }
        for message in messages where shouldNotify(message) {
            let content = UNMutableNotificationContent()
            if showPreviews {
                content.title = message.sender.displayName
                content.body = message.subject.isEmpty ? "(No subject)" : message.subject
                if showAccount { content.subtitle = accountEmail }
            } else {
                content.title = "New message"
                content.body = showAccount ? accountEmail : ""
            }
            content.sound = .default
            content.threadIdentifier = accountID
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["accountID": accountID, "messageID": message.id]
            let request = UNNotificationRequest(identifier: "\(accountID).\(message.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Asks iOS to wake the app to check for mail. iOS decides the actual timing.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "notify.enabled")
        defaults.set(scope.rawValue, forKey: "notify.scope")
        defaults.set(Array(folderIDs), forKey: "notify.folders")
        defaults.set(vipSenders, forKey: "notify.vip")
        defaults.set(showPreviews, forKey: "notify.previews")
        defaults.set(quietHoursEnabled, forKey: "notify.quiet")
        defaults.set(quietStartHour, forKey: "notify.quietStart")
        defaults.set(quietEndHour, forKey: "notify.quietEnd")
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let accountID = info["accountID"] as? String, let messageID = info["messageID"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            if action == UNNotificationDefaultActionIdentifier {
                self.pendingOpen = (accountID, messageID)
            }
        }
        if action == Self.markReadAction || action == Self.archiveAction {
            let handler = await MainActor.run { self.actionHandler }
            await handler?(accountID, messageID, action)
        }
    }
}

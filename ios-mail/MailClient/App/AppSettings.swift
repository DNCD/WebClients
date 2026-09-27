import Observation
import SwiftUI

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum Density: String, CaseIterable, Identifiable {
        case compact, comfortable, spacious
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var rowPadding: CGFloat {
            switch self {
            case .compact: return 2
            case .comfortable: return 6
            case .spacious: return 10
            }
        }
        var avatarSize: CGFloat {
            switch self {
            case .compact: return 32
            case .comfortable: return 40
            case .spacious: return 46
            }
        }
    }

    enum SwipeAction: String, CaseIterable, Identifiable {
        case none, archive, trash, toggleRead, star, spam, moveToInbox
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "None"
            case .archive: return "Archive"
            case .trash: return "Trash"
            case .toggleRead: return "Read / Unread"
            case .star: return "Star / Unstar"
            case .spam: return "Spam"
            case .moveToInbox: return "Move to Inbox"
            }
        }

        var systemImage: String {
            switch self {
            case .none: return "nosign"
            case .archive: return "archivebox.fill"
            case .trash: return "trash.fill"
            case .toggleRead: return "envelope.open.fill"
            case .star: return "star.fill"
            case .spam: return "xmark.octagon.fill"
            case .moveToInbox: return "tray.and.arrow.down.fill"
            }
        }

        var tint: Color {
            switch self {
            case .none: return .gray
            case .archive: return .indigo
            case .trash: return .red
            case .toggleRead: return .blue
            case .star: return .yellow
            case .spam: return .orange
            case .moveToInbox: return .teal
            }
        }
    }

    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance") } }
    var density: Density { didSet { save(density.rawValue, "density") } }
    var showsAvatars: Bool { didSet { save(showsAvatars, "showsAvatars") } }
    var previewLines: Int { didSet { save(previewLines, "previewLines") } }
    var leadingSwipe: SwipeAction { didSet { save(leadingSwipe.rawValue, "leadingSwipe") } }
    var leadingSwipeSecondary: SwipeAction { didSet { save(leadingSwipeSecondary.rawValue, "leadingSwipeSecondary") } }
    var trailingSwipe: SwipeAction { didSet { save(trailingSwipe.rawValue, "trailingSwipe") } }
    var trailingSwipeSecondary: SwipeAction { didSet { save(trailingSwipeSecondary.rawValue, "trailingSwipeSecondary") } }
    var confirmDelete: Bool { didSet { save(confirmDelete, "confirmDelete") } }
    var loadImagesAutomatically: Bool { didSet { save(loadImagesAutomatically, "loadImagesAutomatically") } }
    var offlineDays: Int { didSet { save(offlineDays, "offlineDays") } }
    var unifiedInbox: Bool { didSet { save(unifiedInbox, "unifiedInbox") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "settings." + key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "settings." + key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: "settings." + key) as? Int ?? fallback }

        appearance = string("appearance").flatMap(Appearance.init) ?? .system
        density = string("density").flatMap(Density.init) ?? .comfortable
        showsAvatars = bool("showsAvatars", true)
        previewLines = int("previewLines", 2)
        leadingSwipe = string("leadingSwipe").flatMap(SwipeAction.init) ?? .toggleRead
        leadingSwipeSecondary = string("leadingSwipeSecondary").flatMap(SwipeAction.init) ?? .star
        trailingSwipe = string("trailingSwipe").flatMap(SwipeAction.init) ?? .trash
        trailingSwipeSecondary = string("trailingSwipeSecondary").flatMap(SwipeAction.init) ?? .archive
        confirmDelete = bool("confirmDelete", true)
        loadImagesAutomatically = bool("loadImagesAutomatically", false)
        offlineDays = int("offlineDays", 30)
        unifiedInbox = bool("unifiedInbox", true)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "settings." + key)
    }
}

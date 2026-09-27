import SwiftUI

enum Theme {
    static let brand = Color("AccentColor")
    static let protection = Color.green
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.43, green: 0.29, blue: 1.0), Color(red: 0.18, green: 0.45, blue: 0.98)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let cornerRadius: CGFloat = 16
}

/// Circle with the sender's initials, tinted by a stable hash of their address.
struct AvatarView: View {
    let name: String
    let address: String
    var size: CGFloat = 40

    private static let palette: [Color] = [.indigo, .purple, .pink, .orange, .teal, .blue, .mint, .cyan, .brown, .red]

    private var initials: String {
        let source = name.isEmpty ? address : name
        let words = source.split { $0 == " " || $0 == "." || $0 == "@" }.prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    private var color: Color {
        let hash = address.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return Self.palette[Int(hash.magnitude % UInt(Self.palette.count))]
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Green shield shown on messages where trackers were blocked or links cleaned.
struct TrackerShield: View {
    let summary: PrivacySummary
    var showsCount = true

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark.shield.fill")
            if showsCount {
                Text("\(summary.total)")
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.protection)
        .padding(.horizontal, showsCount ? 5 : 0)
        .padding(.vertical, 2)
        .background(showsCount ? Theme.protection.opacity(0.12) : .clear, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if summary.trackers > 0 { parts.append("\(summary.trackers) trackers blocked") }
        if summary.links > 0 { parts.append("\(summary.links) links cleaned") }
        return parts.joined(separator: ", ")
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

extension Date {
    /// "14:05" today, "Mon" this week, "12 Mar" otherwise — like Mail.
    var mailListFormat: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

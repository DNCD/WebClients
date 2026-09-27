import Foundation
import Network
import Observation

/// A message waiting to be sent (composed offline, or whose send failed on a network error).
struct OutboxItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var created = Date()
    var fromAddressID: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    var attachments: [OutgoingAttachment] = []
    var lastError: String?
}

/// Tracks connectivity so the UI can show an offline banner and the outbox can flush on reconnect.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    private var onReconnect: [() -> Void] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    func whenReconnected(_ action: @escaping () -> Void) {
        onReconnect.append(action)
    }

    private func update(_ online: Bool) {
        let cameOnline = online && !isOnline
        isOnline = online
        if cameOnline { onReconnect.forEach { $0() } }
    }
}

extension Error {
    /// True for failures that retrying later could fix (no connection, timeouts, server hiccups).
    var isTransientNetworkError: Bool {
        if let urlError = self as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        if let apiError = self as? APIError, case .server(let status, _, _) = apiError {
            return status >= 500 || status == 429
        }
        return false
    }
}

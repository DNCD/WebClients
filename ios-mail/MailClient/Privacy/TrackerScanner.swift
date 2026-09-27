import Foundation

struct ImageTracker: Codable, Hashable {
    /// Tracking company reported by the proxy, or "Tracking pixel" for heuristic matches.
    let provider: String
    let url: String
}

/// What tracker protection did for one message.
struct PrivacyReport {
    var imageTrackers: [ImageTracker] = []
    var cleanedLinks: [CleanedLink] = []
    var remoteImageCount = 0
    var isScanning = false

    var summary: PrivacySummary {
        PrivacySummary(trackers: imageTrackers.count, links: cleanedLinks.count)
    }

    struct ProviderGroup: Identifiable {
        let name: String
        let urls: [String]
        var id: String { name }
    }

    /// Trackers grouped by provider, for display.
    var providers: [ProviderGroup] {
        Dictionary(grouping: imageTrackers, by: \.provider)
            .map { ProviderGroup(name: $0.key, urls: $0.value.map(\.url)) }
            .sorted { $0.name < $1.name }
    }
}

/// Asks Proton's image proxy which images are trackers, the same dry-run check the web client makes
/// (`loadFakeProxy` → `GET core/v4/images?DryRun=1`, answer in the `x-pm-tracker-provider` header).
/// Nothing is downloaded from the sender's servers.
enum TrackerScanner {
    static let maxImagesChecked = 40
    static let pixelProvider = "Tracking pixel"

    static func scan(_ images: [RemoteImage], api: APIClient) async -> [ImageTracker] {
        var seen = Set<String>()
        let unique = images.filter { seen.insert($0.url).inserted }.prefix(maxImagesChecked)

        return await withTaskGroup(of: ImageTracker?.self) { group in
            for image in unique {
                group.addTask {
                    let provider = await proxyTrackerProvider(for: image.url, api: api)
                    if let provider, !provider.isEmpty {
                        return ImageTracker(provider: provider, url: image.url)
                    }
                    return image.isLikelyPixel ? ImageTracker(provider: pixelProvider, url: image.url) : nil
                }
            }
            var trackers: [ImageTracker] = []
            for await tracker in group {
                if let tracker { trackers.append(tracker) }
            }
            return trackers.sorted { $0.url < $1.url }
        }
    }

    private static func proxyTrackerProvider(for url: String, api: APIClient) async -> String? {
        let request = APIRequest.get("core/v4/images", query: [
            URLQueryItem(name: "Url", value: url),
            URLQueryItem(name: "DryRun", value: "1"),
        ])
        guard let result = try? await api.sendWithResponse(request) else { return nil }
        return result.response.value(forHTTPHeaderField: "x-pm-tracker-provider")
    }
}

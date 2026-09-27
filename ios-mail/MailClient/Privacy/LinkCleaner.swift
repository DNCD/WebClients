import Foundation

/// A link whose tracking parameters were removed.
struct CleanedLink: Codable, Hashable {
    let original: String
    let cleaned: String
    let removed: [String]
}

/// Strips tracking query parameters from links, like the web client's `getUTMTrackersFromURL`
/// (`packages/shared/lib/mail/trackers.ts`, built on TidyURL). Only parameters that exist purely for
/// tracking are removed, so cleaned links keep working.
enum LinkCleaner {
    static let trackingPrefixes = ["utm_", "mtm_", "pk_", "hsa_", "ss_", "oly_", "vero_", "elq", "ml_subscriber"]

    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp",
        "hsctatracking", "mkt_tok", "rb_clickid", "s_cid", "_gl", "_ga", "wickedid", "sc_cid", "trk",
        "trkcampaign", "mbid", "sfmc_id", "_kx", "cmpid", "ncid", "spm", "scm", "ref_src", "epik", "_branch_match_id",
    ]

    static func isTrackingParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return trackingParameters.contains(lower) || trackingPrefixes.contains { lower.hasPrefix($0) }
    }

    /// Returns the cleaned link, or nil when nothing was removed or the link is not http(s).
    static func clean(_ link: String) -> CleanedLink? {
        guard var components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return nil }

        let removed = items.filter { isTrackingParameter($0.name) }
        guard !removed.isEmpty else { return nil }

        let kept = items.filter { !isTrackingParameter($0.name) }
        // Percent-encoded items keep the remaining parameters byte-for-byte.
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        guard let cleaned = components.string else { return nil }
        return CleanedLink(original: link, cleaned: cleaned, removed: removed.map(\.name))
    }

    /// Cleans every URL found in plain text.
    static func cleanText(_ text: String) -> (text: String, cleaned: [CleanedLink]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return (text, [])
        }
        let ns = text as NSString
        var result = text
        var cleaned: [CleanedLink] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let original = ns.substring(with: match.range)
            guard let link = clean(original), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: link.cleaned)
            cleaned.insert(link, at: 0)
        }
        return (result, cleaned)
    }
}

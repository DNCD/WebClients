import Foundation

/// A remote image referenced by a message.
struct RemoteImage: Hashable {
    let url: String
    /// Tiny or hidden images: the classic tracking-pixel shape.
    let isLikelyPixel: Bool
}

/// Rewrites message HTML before display:
/// - tracking parameters are stripped from links;
/// - every remote image is pointed at `pm-proxy://`, so it can only load through Proton's image proxy
///   (never directly from the sender's server, which would reveal your IP and when you read the mail);
/// - `srcset` is dropped so no image can bypass the proxy.
enum HTMLPrivacy {
    struct Result {
        var html: String
        var remoteImages: [RemoteImage]
        var cleanedLinks: [CleanedLink]
    }

    static let proxyScheme = "pm-proxy"

    static func proxyURL(for remote: String) -> String {
        "\(proxyScheme)://image?url=" + (remote.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    static func process(_ html: String) -> Result {
        var images: [RemoteImage] = []
        var links: [CleanedLink] = []

        // Links: <a ... href="...">
        var output = replace(#"(<a\b[^>]*?\bhref\s*=\s*)(["'])(.*?)\2"#, in: html) { groups in
            let href = decodeEntities(groups[3])
            guard let cleaned = LinkCleaner.clean(href) else { return nil }
            links.append(cleaned)
            return groups[1] + groups[2] + encodeEntities(cleaned.cleaned) + groups[2]
        }

        // Images: <img ... src="...">
        output = replace(#"<img\b[^>]*>"#, in: output) { groups in
            var tag = groups[0]
            tag = replace(#"\s+srcset\s*=\s*(["']).*?\1"#, in: tag) { _ in "" }
            let pixel = isLikelyPixel(tag)
            tag = replace(#"(\bsrc\s*=\s*)(["'])(.*?)\2"#, in: tag) { src in
                var url = decodeEntities(src[3]).trimmingCharacters(in: .whitespaces)
                guard isRemote(url) else { return nil }
                if url.hasPrefix("//") { url = "https:" + url }
                images.append(RemoteImage(url: url, isLikelyPixel: pixel))
                return src[1] + src[2] + proxyURL(for: url) + src[2]
            }
            return tag
        }

        // Legacy background="..." attributes and CSS url(...) references.
        output = replace(#"(\bbackground\s*=\s*)(["'])(https?://.*?)\2"#, in: output) { groups in
            let url = decodeEntities(groups[3])
            images.append(RemoteImage(url: url, isLikelyPixel: false))
            return groups[1] + groups[2] + proxyURL(for: url) + groups[2]
        }
        output = replace(#"url\(\s*(['"]?)(https?://[^'")\s]+)\1\s*\)"#, in: output) { groups in
            let url = decodeEntities(groups[2])
            images.append(RemoteImage(url: url, isLikelyPixel: false))
            return "url(" + groups[1] + proxyURL(for: url) + groups[1] + ")"
        }

        return Result(html: output, remoteImages: images, cleanedLinks: links)
    }

    static func isRemote(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    static func isLikelyPixel(_ imgTag: String) -> Bool {
        // Normalise `width = "1"` / `display: none` spacing, keeping the spaces between attributes.
        let tag = imgTag.lowercased().replacingOccurrences(of: #"\s*([=:;])\s*"#, with: "$1", options: .regularExpression)
        let patterns = [
            #"\b(width|height)=["']?[0-2](px)?["'\s/>]"#,
            #"(^|[;"'])(width|height):[0-2](px)?\b"#,
            #"display:none"#,
            #"visibility:hidden"#,
            #"opacity:0(\.0+)?(?![.\d])"#,
        ]
        return patterns.contains { tag.range(of: $0, options: .regularExpression) != nil }
    }

    static func decodeEntities(_ string: String) -> String {
        string.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    static func encodeEntities(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Regex replace where the transform receives capture groups (0 = whole match) and returns the
    /// replacement, or nil to keep the match unchanged.
    static func replace(_ pattern: String, in string: String, transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return string
        }
        let ns = string as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(groups) ?? groups[0]
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

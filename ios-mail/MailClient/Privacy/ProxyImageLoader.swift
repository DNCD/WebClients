import Foundation
import WebKit

/// Serves `pm-proxy://image?url=…` requests from message HTML through Proton's image proxy
/// (`GET core/v4/images`), so remote images never load directly from the sender. While remote content
/// is off, every image is answered with a transparent pixel instead.
@MainActor
final class ProxyImageLoader: NSObject, WKURLSchemeHandler {
    private let api: APIClient
    var allowsRemoteContent = false
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(api: APIClient) {
        self.api = api
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard allowsRemoteContent,
              let remote = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value else {
            respond(urlSchemeTask, url: requestURL, data: Self.transparentGIF, mimeType: "image/gif")
            return
        }

        tasks[id] = Task { [api] in
            defer { self.tasks[id] = nil }
            do {
                let (data, response) = try await api.sendWithResponse(.get("core/v4/images", query: [
                    URLQueryItem(name: "Url", value: remote),
                    URLQueryItem(name: "DryRun", value: "0"),
                ]))
                guard self.tasks[id] != nil, !Task.isCancelled else { return }
                // A 204 means the proxy could not fetch the image.
                guard response.statusCode != 204, !data.isEmpty else { throw URLError(.resourceUnavailable) }
                self.respond(urlSchemeTask, url: requestURL, data: data, mimeType: response.mimeType ?? "image/png")
            } catch {
                guard self.tasks[id] != nil, !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    private static let transparentGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
}

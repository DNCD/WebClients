import Foundation

/// A single call to the Proton API. Paths mirror `packages/shared/lib/api/*` in the web client.
struct APIRequest {
    enum Method: String {
        case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
    }

    enum Body {
        case json([String: Any])
        case multipart(MultipartForm)
    }

    var method: Method
    var path: String
    var query: [URLQueryItem] = []
    var body: Body?
    /// Unauthenticated calls (login) are sent without the session headers.
    var authenticated = true

    static func get(_ path: String, query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .get, path: path, query: query)
    }

    static func post(_ path: String, _ body: [String: Any], authenticated: Bool = true) -> APIRequest {
        APIRequest(method: .post, path: path, body: .json(body), authenticated: authenticated)
    }

    static func put(_ path: String, _ body: [String: Any]) -> APIRequest {
        APIRequest(method: .put, path: path, body: .json(body))
    }
}

struct SessionTokens: Codable, Equatable {
    var uid: String
    var accessToken: String
    var refreshToken: String
}

/// Thin URLSession wrapper handling Proton's headers, error envelope and token refresh.
actor APIClient {
    private let baseURL: URL
    private let appVersion: String
    private let urlSession: URLSession
    private var refreshTask: Task<SessionTokens, Error>?

    private(set) var tokens: SessionTokens?
    /// Called whenever tokens change so they can be persisted.
    private var onTokensChanged: (@Sendable (SessionTokens?) -> Void)?

    init(baseURL: URL = AppConfig.apiBaseURL,
         appVersion: String = AppConfig.appVersion,
         urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.appVersion = appVersion
        self.urlSession = urlSession
    }

    func setTokens(_ tokens: SessionTokens?) {
        self.tokens = tokens
        onTokensChanged?(tokens)
    }

    func setOnTokensChanged(_ handler: @escaping @Sendable (SessionTokens?) -> Void) {
        onTokensChanged = handler
    }

    func send<T: Decodable>(_ request: APIRequest, as type: T.Type = T.self) async throws -> T {
        let data = try await sendRaw(request)
        do {
            return try JSONDecoder.proton.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    @discardableResult
    func sendRaw(_ request: APIRequest) async throws -> Data {
        do {
            return try await perform(request, tokens: request.authenticated ? tokens : nil)
        } catch APIError.unauthorized where request.authenticated && tokens != nil {
            let refreshed = try await refreshTokens()
            return try await perform(request, tokens: refreshed)
        }
    }

    private func perform(_ request: APIRequest, tokens: SessionTokens?) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: false)!
        if !request.query.isEmpty {
            components.queryItems = request.query
        }
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue(appVersion, forHTTPHeaderField: "x-pm-appversion")
        urlRequest.setValue("application/vnd.protonmail.v1+json", forHTTPHeaderField: "Accept")
        if let tokens {
            urlRequest.setValue(tokens.uid, forHTTPHeaderField: "x-pm-uid")
            urlRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        switch request.body {
        case .json(let object):
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: object)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .multipart(let form):
            urlRequest.httpBody = form.encoded()
            urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        case nil:
            break
        }

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        let envelope = try? JSONDecoder.proton.decode(ErrorEnvelope.self, from: data)

        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode,
                                  code: envelope?.code ?? 0,
                                  message: envelope?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        // Proton reports success with Code 1000 (single) or 1001 (multi-status).
        if let code = envelope?.code, code != 1000, code != 1001 {
            throw APIError.server(status: http.statusCode, code: code, message: envelope?.error ?? "Request failed")
        }
        return data
    }

    /// Mobile-style token refresh (`/auth/v4/refresh`), as used by ProtonCore's RefreshEndpoint.
    /// Concurrent 401s share one refresh.
    private func refreshTokens() async throws -> SessionTokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let current = tokens else { throw APIError.unauthorized }
        let task = Task { () throws -> SessionTokens in
            let request = APIRequest.post("auth/v4/refresh", [
                "ResponseType": "token",
                "GrantType": "refresh_token",
                "RefreshToken": current.refreshToken,
                "RedirectURI": "http://protonmail.ch",
            ])
            do {
                // The refresh call identifies the session by UID only.
                let data = try await perform(request, tokens: SessionTokens(uid: current.uid, accessToken: "", refreshToken: ""))
                let response = try JSONDecoder.proton.decode(RefreshResponse.self, from: data)
                return SessionTokens(uid: current.uid, accessToken: response.accessToken, refreshToken: response.refreshToken)
            } catch {
                throw APIError.sessionExpired
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            setTokens(refreshed)
            return refreshed
        } catch {
            setTokens(nil)
            throw error
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case sessionExpired
    case decoding(Error)
    case server(status: Int, code: Int, message: String)

    var code: Int? {
        if case .server(_, let code, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .unauthorized: return "You are not signed in."
        case .sessionExpired: return "Your session expired. Please sign in again."
        case .decoding(let error): return "Unexpected server data: \(error.localizedDescription)"
        case .server(_, let code, let message):
            if code == ProtonCode.humanVerificationRequired {
                return "Proton requires human verification for this sign-in, which this app does not support yet. Sign in once on the web, then try again."
            }
            return message
        }
    }
}

enum ProtonCode {
    static let humanVerificationRequired = 9001
    static let wrongPassword = 8002
    /// `KEY_GET_DOMAIN_EXTERNAL`: the recipient's domain is not hosted by Proton.
    static let keyGetDomainExternal = 33103
}

private struct ErrorEnvelope: Decodable {
    let code: Int?
    let error: String?
}

extension JSONDecoder {
    /// Maps Proton's PascalCase keys (`AddressID`, `UID`, `MIMEType`) onto camelCase properties
    /// (`addressID`, `uid`, `mimeType`).
    static let proton: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            ProtonCodingKey(stringValue: ProtonCodingKey.camelCase(path.last!.stringValue))
        }
        return decoder
    }()
}

struct ProtonCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    /// Lowercases the leading run of capitals, keeping the last one when it starts the next word:
    /// `ID`→`id`, `UID`→`uid`, `SRPSession`→`srpSession`, `MIMEType`→`mimeType`, `ToList`→`toList`.
    static func camelCase(_ key: String) -> String {
        let chars = Array(key)
        var run = 0
        while run < chars.count, chars[run].isUppercase { run += 1 }
        if run == 0 { return key }
        if run == chars.count { return key.lowercased() }
        let lower = run == 1 ? 1 : run - 1
        return String(chars[..<lower]).lowercased() + String(chars[lower...])
    }
}

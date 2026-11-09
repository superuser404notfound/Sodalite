import Foundation

nonisolated struct TraktTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init(_ response: TraktTokenResponse) {
        self.init(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.createdAt + response.expiresIn))
        )
    }

    /// An access token lives seven days. Refreshing a day early keeps a session that only wakes up
    /// once a week from ever presenting a dead one.
    func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 24 * 60 * 60
    }
}

enum TraktError: LocalizedError, Equatable {
    case notConfigured
    case notConnected
    /// 420: the account hit a free-tier limit (watchlist or list size). Retrying cannot help.
    case accountLimit
    /// The refresh token was refused, so the user has to connect again.
    case sessionEnded
    case deviceCodeExpired
    case deviceCodeDenied
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured, .notConnected:
            String(localized: "trakt.error.notConnected", defaultValue: "Trakt is not connected.")
        case .accountLimit:
            String(localized: "trakt.error.accountLimit",
                   defaultValue: "Your Trakt account has reached its limit. Trakt VIP raises it.")
        case .sessionEnded:
            String(localized: "trakt.error.sessionEnded",
                   defaultValue: "Trakt ended the connection. Connect again in Settings.")
        case .deviceCodeExpired:
            String(localized: "trakt.error.codeExpired", defaultValue: "The code expired. Start again.")
        case .deviceCodeDenied:
            String(localized: "trakt.error.codeDenied", defaultValue: "The connection was declined on Trakt.")
        case .http(let status):
            String(localized: "trakt.error.http", defaultValue: "Trakt answered with an error (\(status)).")
        }
    }
}

/// Talks to Trakt for one connected profile at a time.
///
/// Refresh tokens are single use: a second refresh racing the first would present a token Trakt
/// already invalidated and end the session. So every refresh goes through one in-flight task.
@MainActor
final class TraktClient {
    let clientID: String
    private let http: HTTPClient
    private let decoder: JSONDecoder

    private(set) var tokens: TraktTokens?
    /// Told about every rotated token pair, so the store persists it before anything else can run.
    var onTokensChanged: ((TraktTokens?) -> Void)?

    private var refreshTask: Task<TraktTokens, Error>?
    /// Trakt allows one write per second per user; a burst gets 429s.
    private var lastWriteAt: Date = .distantPast

    init(clientID: String, http: HTTPClient = TraktClient.makeHTTPClient()) {
        self.clientID = clientID
        self.http = http
        self.decoder = Self.makeDecoder()
    }

    /// Its own session without the shared response cache: the cache key ignores the bearer header,
    /// so one profile's watchlist could be served to another.
    nonisolated static func makeHTTPClient() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return HTTPClient(session: URLSession(configuration: config))
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = TraktDate.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unreadable Trakt date \(raw)"))
        }
        return decoder
    }

    func setTokens(_ tokens: TraktTokens?) {
        refreshTask?.cancel()
        refreshTask = nil
        self.tokens = tokens
        if let tokens {
            LogSecrets.register(tokens.accessToken)
            LogSecrets.register(tokens.refreshToken)
        }
    }

    // MARK: - Device flow

    func requestDeviceCode() async throws -> TraktDeviceCode {
        try await decode(TraktDeviceCode.self,
                         from: raw(.deviceCode(TraktDeviceCodeRequest(clientID: clientID))))
    }

    /// One poll. nil while the user has not approved yet; throws when the code is dead.
    func pollDeviceToken(_ code: TraktDeviceCode) async throws -> TraktTokens? {
        do {
            let data = try await raw(.deviceToken(TraktDeviceTokenRequest(code: code.deviceCode, clientID: clientID)))
            let tokens = TraktTokens(try decode(TraktTokenResponse.self, from: data))
            setTokens(tokens)
            onTokensChanged?(tokens)
            return tokens
        } catch let error as APIError where Self.isTransient(error) {
            // On iPhone the approval happens in Safari, and iOS suspends the app meanwhile: the
            // poll in flight dies with a transport error while the code is still good. Measured
            // on an iPhone 18 Pro Max (iOS 27), where it ended the whole sign-in.
            return nil
        } catch APIError.httpError(let status, _) {
            switch status {
            case 400, 429: return nil
            case 410, 404, 409: throw TraktError.deviceCodeExpired
            case 418: throw TraktError.deviceCodeDenied
            default: throw TraktError.http(status)
            }
        }
    }

    nonisolated private static func isTransient(_ error: APIError) -> Bool {
        switch error {
        case .networkError, .timeout, .serverUnreachable: true
        default: false
        }
    }

    /// Best effort: the local session goes either way.
    func revoke() async {
        guard let token = tokens?.accessToken else { return }
        _ = try? await raw(.revoke(TraktRevokeRequest(token: token, clientID: clientID)))
    }

    // MARK: - API

    func get<T: Decodable>(_ endpoint: TraktEndpoint, as type: T.Type) async throws -> T {
        try decode(type, from: try await send(endpoint))
    }

    @discardableResult
    func send(_ endpoint: TraktEndpoint) async throws -> Data {
        guard tokens != nil else { throw TraktError.notConnected }
        if tokens?.needsRefresh() == true { _ = try await refreshTokens() }
        do {
            return try await authorized(endpoint)
        } catch APIError.unauthorized {
            _ = try await refreshTokens()
            return try await authorized(endpoint)
        }
    }

    private func authorized(_ endpoint: TraktEndpoint) async throws -> Data {
        guard let token = tokens?.accessToken else { throw TraktError.notConnected }
        if endpoint.isWrite {
            let wait = 1.05 - Date().timeIntervalSince(lastWriteAt)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastWriteAt = Date()
        }
        do {
            return try await raw(endpoint, bearer: token)
        } catch APIError.httpError(let status, _) where status == 429 {
            // Retry-After is not exposed past HTTPClient; Trakt's windows are short.
            try await Task.sleep(for: .seconds(2))
            return try await raw(endpoint, bearer: token)
        } catch APIError.httpError(let status, _) where status == 420 {
            throw TraktError.accountLimit
        }
    }

    private func refreshTokens() async throws -> TraktTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw TraktError.notConnected }
        let task = Task { [clientID] () throws -> TraktTokens in
            let body = TraktRefreshRequest(refreshToken: current.refreshToken, clientID: clientID,
                                           redirectURI: TraktHost.outOfBandRedirect)
            do {
                let data = try await self.raw(.refresh(body))
                return TraktTokens(try self.decode(TraktTokenResponse.self, from: data))
            } catch APIError.httpError(let status, _) where (400...401).contains(status) {
                throw TraktError.sessionEnded
            } catch APIError.unauthorized {
                throw TraktError.sessionEnded
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            setTokens(fresh)
            onTokensChanged?(fresh)
            return fresh
        } catch TraktError.sessionEnded {
            tokens = nil
            onTokensChanged?(nil)
            throw TraktError.sessionEnded
        }
    }

    private func raw(_ endpoint: TraktEndpoint, bearer: String? = nil) async throws -> Data {
        var headers = [
            "trakt-api-version": "2",
            "trakt-api-key": clientID,
            "Accept": "application/json",
        ]
        if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
        let base = endpoint.isAuth ? TraktHost.auth : TraktHost.api
        return try await http.requestData(baseURL: base, endpoint: endpoint, headers: headers).0
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            LogTap.shared.note("[Trakt] decode \(T.self) failed: \(error)")
            throw APIError.decodingError(error)
        }
    }
}

nonisolated enum TraktDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Trakt writes `2014-09-01T09:10:11.000Z`; Jellyfin writes seven fractional digits. Both pass.
    static func parse(_ raw: String) -> Date? {
        if let date = fractional.date(from: raw) ?? plain.date(from: raw) { return date }
        // Jellyfin's 100 ns ticks overflow the formatter: cut the fraction to milliseconds.
        guard let dot = raw.firstIndex(of: "."),
              let zone = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return nil }
        let digits = raw[raw.index(after: dot)..<zone].prefix(3)
        return fractional.date(from: raw[..<dot] + "." + digits + raw[zone...])
    }
}

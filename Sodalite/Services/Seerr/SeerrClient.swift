import Foundation

@MainActor
final class SeerrClient {
    let httpClient: HTTPClientProtocol

    var baseURL: URL?
    var sessionCookie: String? {
        didSet { if let sessionCookie { onSessionCookieSet?(sessionCookie) } }
    }
    /// Set by `DependencyContainer`, so the cookie reaches the log redactors.
    var onSessionCookieSet: ((String) -> Void)?
    /// The Seerr server `baseURL` belongs to, for the trust check of a LAN address.
    var serverID: String?
    /// Holds a request to a LAN address until the container can say whether this network is one
    /// Seerr may be trusted on, and refuses it otherwise. Seerr cannot be asked who it is, so the
    /// sync alone was not enough: Catalog kept sending the cookie after a network change (audit
    /// review R-ROUTE-23). Set by `DependencyContainer` on the live client only.
    var routeHold: (@MainActor (_ current: () -> URL?) async throws -> URL)?

    private let decoder: JSONDecoder

    init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient

        // Decode converts snake_case (TMDB-shaped responses: poster_path, vote_average). POST bodies stay camelCase (HTTPClient.encoder); the API rejects snake_case bodies with HTTP 500.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func request<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> T {
        let (data, _) = try await send(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func request(endpoint: APIEndpoint) async throws {
        _ = try await send(endpoint)
    }

    /// Raw variant for endpoints whose 2xx responses aren't always the expected payload (POST /request answers 202 + error JSON when nothing is requestable); caller checks the status before decoding via `decode(_:from:)`.
    func requestData(endpoint: APIEndpoint) async throws -> (Data, HTTPURLResponse) {
        try await send(endpoint)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func requestWithResponse<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await send(endpoint)
        do {
            let value = try decoder.decode(T.self, from: data)
            return (value, response)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// The one path every call takes. A 401 on the cookie this client still holds says Seerr no longer
    /// knows the session, which no retry can fix, so it is announced for the app-wide re-check
    /// (`SeerrSessionRejectionHandler`). A cookie swapped during the request (profile switch) belongs to someone else's verdict.
    private func send(_ endpoint: APIEndpoint) async throws -> (Data, HTTPURLResponse) {
        guard var baseURL else { throw APIError.invalidURL }
        if let routeHold, RouteGate.needsProof(baseURL) {
            baseURL = try await routeHold { self.baseURL }
        }
        let sentCookie = endpoint.requiresAuth ? sessionCookie : nil
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        do {
            return try await httpClient.requestData(
                baseURL: baseURL,
                endpoint: endpoint,
                headers: headers
            )
        } catch let error as APIError {
            if case .unauthorized = error, let sentCookie, sentCookie == sessionCookie {
                NotificationCenter.default.post(name: .seerrSessionRejected, object: self)
            }
            throw error
        }
    }

    /// Honor `requiresAuth` so the cookie isn't attached to the /auth/jellyfin POST, where a stale connect.sid would poison the fresh login.
    private func buildHeaders(requiresAuth: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        headers["Accept"] = "application/json"
        if requiresAuth, let sessionCookie {
            headers["Cookie"] = sessionCookie
        }
        return headers
    }

    func extractSessionCookie(from response: HTTPURLResponse) -> String? {
        guard let baseURL,
              let headerFields = response.allHeaderFields as? [String: String]
        else { return nil }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: baseURL)
        guard let sessionCookie = cookies.first(where: { $0.name == "connect.sid" }) else {
            return nil
        }
        return "\(sessionCookie.name)=\(sessionCookie.value)"
    }
}

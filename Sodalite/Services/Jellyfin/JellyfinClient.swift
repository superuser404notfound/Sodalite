import Foundation

@MainActor
final class JellyfinClient {
    let httpClient: HTTPClientProtocol
    /// Stable per-install device id (auth header + stream URLs). Exposed because /Videos/ActiveEncodings kills transcodes by (DeviceId, PlaySessionId).
    private(set) var deviceID: String
    private let appVersion: String

    var baseURL: URL?
    var accessToken: String? {
        didSet { if let accessToken { onAccessTokenSet?(accessToken) } }
    }
    /// Set by `DependencyContainer` on the live client only, so the token reaches the log redactors.
    var onAccessTokenSet: ((String) -> Void)?
    /// Holds requests back from a LAN address that has not proved it is this session's server
    /// (audit NET-201). nil on a sign-in client, whose route is resolved before it sends anything.
    var routeGate: RouteGate?
    /// A sign-in client's route probe while it runs, so the screens share one (audit review R-ROUTE-24).
    var pendingRouteResolve: Task<URL, Never>?

    /// `accessToken` for a URL built on the spot (image `api_key`, a download's header), or nil
    /// while the address has not proved itself, so such a URL goes out without it.
    var verifiedAccessToken: String? {
        guard let baseURL, routeGate?.allows(baseURL) ?? true else { return nil }
        return accessToken
    }

    /// `baseURL` once credentials may go there, nil before.
    var verifiedBaseURL: URL? {
        guard let baseURL, routeGate?.allows(baseURL) ?? true else { return nil }
        return baseURL
    }

    init(httpClient: HTTPClientProtocol = HTTPClient()) {
        self.httpClient = httpClient
        self.deviceID = Self.getOrCreateDeviceID()
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func request<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type
    ) async throws -> T {
        let baseURL = try await admittedBaseURL()
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        return try await httpClient.request(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers,
            responseType: responseType
        )
    }

    /// Variant with a caller-supplied decoder, needed for Live TV whose date format the shared `.iso8601` decoder can't parse.
    func request<T: Decodable>(
        endpoint: APIEndpoint,
        responseType: T.Type,
        decoder: JSONDecoder
    ) async throws -> T {
        let baseURL = try await admittedBaseURL()
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        let (data, _) = try await httpClient.requestData(
            baseURL: baseURL, endpoint: endpoint, headers: headers)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Mirror HTTPClient.request: localized message instead of raw DecodingError.
            throw APIError.decodingError(error)
        }
    }

    func request(endpoint: APIEndpoint) async throws {
        let baseURL = try await admittedBaseURL()
        let headers = buildHeaders(requiresAuth: endpoint.requiresAuth)
        try await httpClient.request(
            baseURL: baseURL,
            endpoint: endpoint,
            headers: headers
        )
    }

    /// Every request waits here, the unauthenticated ones included: the stored-password login is one
    /// of them.
    func admittedBaseURL() async throws -> URL {
        guard let routeGate else {
            guard let baseURL else { throw APIError.invalidURL }
            return baseURL
        }
        return try await routeGate.admit { baseURL }
    }

    func buildAuthHeader() -> String {
        buildMediaBrowserHeader(includeToken: true)
    }

    /// Single owner of the MediaBrowser header so client/device/version can't drift between the engine device profile and per-request headers.
    private func buildMediaBrowserHeader(includeToken: Bool) -> String {
        var authParts = [
            "Client=\"Sodalite\"",
            "Device=\"Apple TV\"",
            "DeviceId=\"\(deviceID)\"",
            "Version=\"\(appVersion)\"",
        ]
        if includeToken, let token = accessToken {
            authParts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser \(authParts.joined(separator: ", "))"
    }

    private func buildHeaders(requiresAuth: Bool) -> [String: String] {
        [
            "Authorization": buildMediaBrowserHeader(includeToken: requiresAuth),
            "Accept": "application/json",
        ]
    }

    private static func getOrCreateDeviceID() -> String {
        let key = "Sodalite_DeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
}

import Foundation

/// Lean Jellyfin client for the TopShelf (/Items/Resume, /Shows/NextUp). Not the main app's client: pulling in its DI graph would blow the extension's tight memory budget for one or two GETs.
nonisolated struct TopShelfAPI: Sendable {
    let session: SharedSession

    private static let deviceID: String = {
        // Stable per-extension device id (App Group UserDefaults, distinct from the main app's) so shelf refreshes don't fill Jellyfin's session list with one-off rows.
        let defaults = UserDefaults(suiteName: "group.de.superuser404.Sodalite")
        let key = "topShelf.deviceID"
        if let existing = defaults?.string(forKey: key) { return existing }
        let new = UUID().uuidString
        defaults?.set(new, forKey: key)
        return new
    }()

    func resumeItems(limit: Int = 10) async throws -> [TopShelfItem] {
        let url = endpoint(
            path: "/Users/\(session.userID)/Items/Resume",
            query: [
                "MediaTypes": "Video",
                "Limit": "\(limit)",
                "Fields": Self.fields,
            ]
        )
        let response: ItemsResponse = try await get(url)
        return response.items ?? []
    }

    func nextUp(limit: Int = 10) async throws -> [TopShelfItem] {
        let url = endpoint(
            path: "/Shows/NextUp",
            query: [
                "UserId": session.userID,
                "Limit": "\(limit)",
                "Fields": Self.fields,
                // Matches the app's Next Up row (JellyfinEndpoints.nextUp). Without it a
                // part-watched episode lands in both shelf sections, since Resume and Next Up are
                // fetched independently and nothing dedups them. Older servers ignore it.
                "EnableResumable": "false",
            ]
        )
        let response: ItemsResponse = try await get(url)
        return response.items ?? []
    }

    private func endpoint(path: String, query: [String: String]) -> URL {
        var base = session.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// Ephemeral and uncached: the shelf has to reflect what was just watched, and a response cached
    /// on the strength of a proxy's headers would hand back the previous state. The resource
    /// timeout caps the whole request; the request timeout alone only measures idle gaps, so a
    /// server trickling bytes could hold the shelf's answer indefinitely.
    ///
    /// A secondary server of a combined shelf gets a shorter cap (Sodalite#218): the shelf waits for
    /// its slowest server, and one that is away must cost the active server's rows as little as
    /// Home's own deadline for it does.
    private static let urlSession = makeSession(request: 8, resource: 10)
    private static let secondaryURLSession = makeSession(request: 4, resource: 4)

    private static func makeSession(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = resource
        return URLSession(configuration: configuration)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let urlSession = session.serverID == nil ? Self.urlSession : Self.secondaryURLSession
        let (data, response) = try await urlSession.data(for: request)
        // A 401 after a token rotation used to surface as a JSON decode error, which named the
        // wrong cause in the log.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TopShelfHTTPError(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private var authHeader: String {
        let parts = [
            "Client=\"Sodalite\"",
            "Device=\"Apple TV\"",
            "DeviceId=\"\(Self.deviceID)\"",
            "Version=\"1.0\"",
            "Token=\"\(session.accessToken)\"",
        ]
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// `ParentThumbImageTag` rides along for the Thumb artwork option; a server that does not fill
    /// it simply leaves that chain empty and the cell falls through to the backdrop. `ProviderIds`
    /// is what a combined shelf recognises one title on two servers by.
    private static let fields = "ImageTags,BackdropImageTags,ParentBackdropImageTags,ParentThumbImageTag,ProviderIds"
}

nonisolated private struct ItemsResponse: Decodable {
    let items: [TopShelfItem]?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

nonisolated struct TopShelfHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? { "HTTP \(status)" }
}

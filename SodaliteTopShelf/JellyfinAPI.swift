import Foundation

/// Lean Jellyfin client for the TopShelf (/Items/Resume, /Shows/NextUp). Not the main app's client: pulling in its DI graph would blow the extension's tight memory budget for one or two GETs.
struct JellyfinAPI: Sendable {
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

    func resumeItems(limit: Int = 10) async throws -> [JellyfinItem] {
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

    func nextUp(limit: Int = 10) async throws -> [JellyfinItem] {
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

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
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
    /// it simply leaves that chain empty and the cell falls through to the backdrop.
    private static let fields = "ImageTags,BackdropImageTags,ParentBackdropImageTags,ParentThumbImageTag"
}

private struct ItemsResponse: Decodable {
    let items: [JellyfinItem]?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

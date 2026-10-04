import Foundation

/// Which Jellyfin token an image request may carry. Matched against each participating server's
/// base URL (scheme, host, port and path), longest first, so neither a second server on the same
/// box nor one behind the same reverse proxy under another path receives the first one's token
/// (Sodalite#85). A value, so a detached prefetch can take it along.
nonisolated struct ImageAuth: Sendable {
    private let entries: [(prefix: String, token: String)]

    init(bases: [(baseURL: URL, token: String)]) {
        entries = bases.compactMap { base in
            Self.normalized(base.baseURL).map { ($0, base.token) }
        }.sorted { $0.prefix.count > $1.prefix.count }
    }

    func token(for url: URL) -> String? {
        guard let target = Self.normalized(url) else { return nil }
        return entries.first { target == $0.prefix || target.hasPrefix($0.prefix + "/") }?.token
    }

    /// `scheme://host:port/path` with an explicit port and no trailing slash.
    private static func normalized(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path)"
    }

    @MainActor
    static func snapshot(_ registry: ServerSessionRegistry) -> ImageAuth {
        ImageAuth(bases: registry.participants.compactMap { session in
            guard let base = session.client.baseURL,
                  let token = session.client.accessToken, !token.isEmpty else { return nil }
            return (base, token)
        })
    }
}

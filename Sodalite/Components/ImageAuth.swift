import Foundation

/// Which Jellyfin token an image request may carry, by host AND port, so a second server on the
/// same box never receives the first one's token (Sodalite#85). A value, so a detached prefetch
/// can take it along.
nonisolated struct ImageAuth: Sendable {
    let tokens: [String: String]

    static func key(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    func token(for url: URL) -> String? {
        Self.key(for: url).flatMap { tokens[$0] }
    }

    @MainActor
    static func snapshot(_ registry: ServerSessionRegistry) -> ImageAuth {
        var tokens: [String: String] = [:]
        for session in registry.participants {
            guard let base = session.client.baseURL, let key = key(for: base),
                  let token = session.client.accessToken, !token.isEmpty else { continue }
            tokens[key] = token
        }
        return ImageAuth(tokens: tokens)
    }
}

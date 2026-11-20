import Foundation

/// Body for `POST /api/v1/auth/jellyfin`: credentials only, no `hostname` (re-sending it on a configured server returns HTTP 500 "jellyfin hostname already configured").
struct SeerrJellyfinAuthBody: Encodable, Sendable {
    let username: String
    let password: String
}

/// Body for `POST /api/v1/auth/local`: Seerr matches `email` lowercased against its own users.
struct SeerrLocalAuthBody: Encodable, Sendable {
    let email: String
    let password: String
}

/// The slice of `GET /api/v1/settings/public` that says which sign-in routes the server accepts.
/// Optional throughout: older Overseerr/Jellyseerr builds omit some of these.
nonisolated struct SeerrPublicSettings: Decodable, Sendable {
    let localLogin: Bool?
    let mediaServerLogin: Bool?
    let mediaServerType: Int?

    /// `/auth/jellyfin` answers HTTP 500 "Jellyfin login is disabled" unless the server is Jellyfin (2),
    /// Emby (3) or not configured (4), and media-server sign-in is on (Sodalite#214: a Plex-backed Seerr).
    var acceptsJellyfinLogin: Bool {
        if mediaServerLogin == false { return false }
        guard let mediaServerType else { return true }
        return [2, 3, 4].contains(mediaServerType)
    }

    var acceptsLocalLogin: Bool { localLogin != false }
}

/// Which Seerr endpoint a sign-in with typed (non-Jellyfin-profile) credentials goes to first.
enum SeerrLoginRoute: Equatable, Sendable {
    case jellyfin
    case local

    /// Local accounts sign in by email, so an identifier without "@" only goes local when the server
    /// accepts nothing else. Unknown settings keep the pre-#214 Jellyfin route for non-email input.
    static func resolve(identifier: String, settings: SeerrPublicSettings?) -> SeerrLoginRoute {
        if let settings {
            if !settings.acceptsJellyfinLogin { return .local }
            if !settings.acceptsLocalLogin { return .jellyfin }
        }
        return identifier.contains("@") ? .local : .jellyfin
    }
}

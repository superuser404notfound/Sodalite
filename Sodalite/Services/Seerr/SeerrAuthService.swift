import Foundation

protocol SeerrAuthServiceProtocol: Sendable {
    func loginWithJellyfin(username: String, password: String) async throws -> SeerrUser
    func loginWithLocal(email: String, password: String) async throws -> SeerrUser
    func publicSettings() async throws -> SeerrPublicSettings
    func currentUser() async throws -> SeerrUser
    func logout() async throws
}

extension SeerrAuthServiceProtocol {
    /// Typed credentials: a local Seerr account (email) or a Jellyfin account other than the active profile's.
    /// Tries the route the server's settings point to, then the other one when Seerr rejects the
    /// credentials and also accepts it, so a Jellyfin username that is an email still signs in.
    func loginWithTypedCredentials(
        identifier: String,
        password: String,
        settings: SeerrPublicSettings?
    ) async throws -> SeerrUser {
        let first = SeerrLoginRoute.resolve(identifier: identifier, settings: settings)
        do {
            return try await login(via: first, identifier: identifier, password: password)
        } catch let error as APIError where error.isCredentialRejection {
            let other: SeerrLoginRoute = first == .local ? .jellyfin : .local
            let otherAccepted = switch other {
            case .jellyfin: settings?.acceptsJellyfinLogin ?? true
            case .local: (settings?.acceptsLocalLogin ?? true) && identifier.contains("@")
            }
            guard otherAccepted else { throw error }
            return try await login(via: other, identifier: identifier, password: password)
        }
    }

    private func login(via route: SeerrLoginRoute, identifier: String, password: String) async throws -> SeerrUser {
        switch route {
        case .jellyfin: try await loginWithJellyfin(username: identifier, password: password)
        case .local: try await loginWithLocal(email: identifier, password: password)
        }
    }
}

private extension APIError {
    /// Seerr's "these credentials are wrong" answers: 401 from /auth/jellyfin, 403 from /auth/local.
    var isCredentialRejection: Bool {
        switch self {
        case .unauthorized: true
        case .httpError(let statusCode, _): statusCode == 403
        default: false
        }
    }
}

@MainActor
final class SeerrAuthService: SeerrAuthServiceProtocol {
    private let client: SeerrClient

    init(client: SeerrClient) {
        self.client = client
    }

    func loginWithJellyfin(username: String, password: String) async throws -> SeerrUser {
        let body = SeerrJellyfinAuthBody(username: username, password: password)
        return try await signIn(endpoint: .authJellyfin(body: body))
    }

    func loginWithLocal(email: String, password: String) async throws -> SeerrUser {
        let body = SeerrLocalAuthBody(email: email, password: password)
        return try await signIn(endpoint: .authLocal(body: body))
    }

    func publicSettings() async throws -> SeerrPublicSettings {
        try await client.request(
            endpoint: SeerrEndpoint.publicSettings,
            responseType: SeerrPublicSettings.self
        )
    }

    private func signIn(endpoint: SeerrEndpoint) async throws -> SeerrUser {
        // Drop any residual cookie: a stale connect.sid makes Seerr 401 the fresh credentials before reading the body.
        client.sessionCookie = nil

        let (user, response) = try await client.requestWithResponse(
            endpoint: endpoint,
            responseType: SeerrUser.self
        )
        guard let cookie = client.extractSessionCookie(from: response) else {
            throw APIError.unauthorized(message: nil)
        }
        client.sessionCookie = cookie
        return user
    }

    func currentUser() async throws -> SeerrUser {
        try await client.request(
            endpoint: SeerrEndpoint.authMe,
            responseType: SeerrUser.self
        )
    }

    func logout() async throws {
        try await client.request(endpoint: SeerrEndpoint.authLogout)
        client.sessionCookie = nil
    }
}

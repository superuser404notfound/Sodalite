import Testing
import Foundation
@testable import Sodalite

/// Sodalite#214: a Seerr backed by Plex answers /auth/jellyfin with HTTP 500 "Jellyfin login is
/// disabled", so typed credentials have to reach /auth/local there.
@MainActor
struct SeerrLoginRouteTests {

    private func settings(_ json: String) throws -> SeerrPublicSettings {
        try JSONDecoder().decode(SeerrPublicSettings.self, from: Data(json.utf8))
    }

    @Test func plexServerGoesLocalEvenWithoutAnEmail() throws {
        let plex = try settings(#"{"localLogin":true,"mediaServerLogin":true,"mediaServerType":1}"#)
        #expect(!plex.acceptsJellyfinLogin)
        #expect(SeerrLoginRoute.resolve(identifier: "tom", settings: plex) == .local)
    }

    @Test func mediaServerLoginOffGoesLocal() throws {
        let off = try settings(#"{"localLogin":true,"mediaServerLogin":false,"mediaServerType":2}"#)
        #expect(SeerrLoginRoute.resolve(identifier: "tom", settings: off) == .local)
    }

    @Test func jellyfinServerSplitsOnTheEmailShape() throws {
        let jellyfin = try settings(#"{"localLogin":true,"mediaServerLogin":true,"mediaServerType":2}"#)
        #expect(SeerrLoginRoute.resolve(identifier: "tom", settings: jellyfin) == .jellyfin)
        #expect(SeerrLoginRoute.resolve(identifier: "tom@example.com", settings: jellyfin) == .local)
    }

    @Test func localLoginOffKeepsJellyfin() throws {
        let noLocal = try settings(#"{"localLogin":false,"mediaServerLogin":true,"mediaServerType":3}"#)
        #expect(SeerrLoginRoute.resolve(identifier: "tom@example.com", settings: noLocal) == .jellyfin)
    }

    @Test func unknownSettingsKeepThePreviousRouteForUsernames() {
        #expect(SeerrLoginRoute.resolve(identifier: "tom", settings: nil) == .jellyfin)
        #expect(SeerrLoginRoute.resolve(identifier: "tom@example.com", settings: nil) == .local)
    }

    @Test func missingFieldsDecodeAsPermissive() throws {
        let bare = try settings("{}")
        #expect(bare.acceptsJellyfinLogin)
        #expect(bare.acceptsLocalLogin)
    }

    private final class RecordingAuth: SeerrAuthServiceProtocol, @unchecked Sendable {
        var calls: [SeerrLoginRoute] = []
        var localError: APIError?
        var jellyfinError: APIError?

        func loginWithJellyfin(username: String, password: String) async throws -> SeerrUser {
            calls.append(.jellyfin)
            if let jellyfinError { throw jellyfinError }
            return .stub
        }
        func loginWithLocal(email: String, password: String) async throws -> SeerrUser {
            calls.append(.local)
            if let localError { throw localError }
            return .stub
        }
        func publicSettings() async throws -> SeerrPublicSettings { throw APIError.invalidResponse }
        func currentUser() async throws -> SeerrUser { .stub }
        func logout() async throws {}
    }

    /// A Jellyfin username that happens to be an email: local rejects it with 403, Jellyfin signs in.
    @Test func rejectedLocalFallsBackToJellyfin() async throws {
        let auth = RecordingAuth()
        auth.localError = .httpError(statusCode: 403, data: nil)
        let jellyfin = try settings(#"{"localLogin":true,"mediaServerLogin":true,"mediaServerType":2}"#)
        _ = try await auth.loginWithTypedCredentials(identifier: "tom@example.com", password: "p", settings: jellyfin)
        #expect(auth.calls == [.local, .jellyfin])
    }

    @Test func plexServerNeverFallsBackToJellyfin() async throws {
        let auth = RecordingAuth()
        auth.localError = .httpError(statusCode: 403, data: nil)
        let plex = try settings(#"{"localLogin":true,"mediaServerLogin":true,"mediaServerType":1}"#)
        await #expect(throws: APIError.self) {
            _ = try await auth.loginWithTypedCredentials(identifier: "tom@example.com", password: "p", settings: plex)
        }
        #expect(auth.calls == [.local])
    }

    /// A rejected username without "@" never goes local: Seerr only matches local accounts by email.
    @Test func rejectedUsernameDoesNotTryLocal() async throws {
        let auth = RecordingAuth()
        auth.jellyfinError = .unauthorized(message: nil)
        await #expect(throws: APIError.self) {
            _ = try await auth.loginWithTypedCredentials(identifier: "tom", password: "p", settings: nil)
        }
        #expect(auth.calls == [.jellyfin])
    }

    /// A server error is not a credential verdict, so it surfaces instead of trying the other route.
    @Test func serverErrorIsNotRetried() async throws {
        let auth = RecordingAuth()
        auth.localError = .httpError(statusCode: 500, data: nil)
        await #expect(throws: APIError.self) {
            _ = try await auth.loginWithTypedCredentials(identifier: "tom@example.com", password: "p", settings: nil)
        }
        #expect(auth.calls == [.local])
    }
}

private extension SeerrUser {
    static var stub: SeerrUser {
        try! JSONDecoder().decode(SeerrUser.self, from: Data(#"{"id":1}"#.utf8))
    }
}

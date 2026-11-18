import Foundation
import Testing
@testable import Sodalite

/// "Sign out on all devices" (audit 2026-09-25 SESSION-5). The token is revoked on the server first,
/// with the profile's own token on a client of its own, and only an answer that proves the token is
/// dead removes the profile. A failure leaves the device exactly as it was, so the user can retry.
@Suite("Signing a profile out on all devices", .serialized)
@MainActor
struct SignOutEverywhereTests {
    private let server = JellyfinServer(
        id: "srv-soe", name: "Home", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil
    )

    private func signedIn() throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        // The genuine server answers at its address; the stranger case stubs its own.
        container.jellyfinProbe = { _, _ in true }
        let active = try JSONDecoder().decode(
            JellyfinUser.self,
            from: Data(#"{"Id":"user-a","Name":"Vincent","ServerId":"srv-soe"}"#.utf8)
        )
        try container.saveSession(server: server, user: active, token: "token-user-a", password: "hunter2")
        try container.rememberUser(other)
        try container.keychainService.save(
            "secret-b", for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: other.id)
        )
        return container
    }

    private let other = RememberedUser(
        id: "user-b", serverID: "srv-soe", name: "Kid", imageTag: nil, token: "token-user-b"
    )

    private func ids(_ container: DependencyContainer) -> [String] {
        container.listRememberedUsers(serverID: server.id).map(\.id).sorted()
    }

    @Test func theEndpointIsAnAuthenticatedPost() {
        let endpoint = JellyfinEndpoint.sessionLogout
        #expect(endpoint.path == "/Sessions/Logout")
        #expect(endpoint.method == .post)
        #expect(endpoint.requiresAuth)
    }

    @Test func aRevokedProfileIsForgottenWithItsCredentials() async throws {
        let container = try signedIn()
        let liveToken = container.jellyfinClient.accessToken
        let liveURL = container.jellyfinClient.baseURL
        var revokedWith: (token: String?, isLive: Bool)?

        let outcome = try await container.signOutEverywhere(other, server: server) { client in
            revokedWith = (client.accessToken, client === container.jellyfinClient)
        }

        #expect(outcome == .forgotten)
        #expect(revokedWith?.token == "token-user-b")
        #expect(revokedWith?.isLive == false)
        #expect(container.jellyfinClient.accessToken == liveToken)
        #expect(container.jellyfinClient.baseURL == liveURL)
        #expect(ids(container) == ["user-a"])
        #expect(container.listForgottenUsers(serverID: server.id)["user-b"] != nil)
        let password = try? container.keychainService.loadString(
            for: KeychainKeys.jellyfinPassword(serverID: server.id, userID: "user-b")
        )
        #expect(password == nil)
    }

    /// A token the server already refuses is as revoked as it gets.
    @Test func anAlreadyDeadTokenCountsAsRevoked() async throws {
        let container = try signedIn()

        let outcome = try await container.signOutEverywhere(other, server: server) { _ in
            throw APIError.unauthorized(message: nil)
        }

        #expect(outcome == .forgotten)
        #expect(ids(container) == ["user-a"])
    }

    /// Audit review R-ROUTE-4: a 401 from an address that does not answer as this server says
    /// nothing about the token, so it must not be logged as revoked and the profile stays.
    @Test func aRefusalFromAStrangerRevokesNothing() async throws {
        let container = try signedIn()
        container.jellyfinIdentity = { _, _ in .otherServer }

        await #expect(throws: APIError.self) {
            try await container.signOutEverywhere(other, server: server) { _ in
                throw APIError.unauthorized(message: nil)
            }
        }

        #expect(ids(container) == ["user-a", "user-b"])
        #expect(container.listForgottenUsers(serverID: server.id).isEmpty)
    }

    @Test func aNetworkFailureChangesNothing() async throws {
        let container = try signedIn()

        await #expect(throws: APIError.self) {
            try await container.signOutEverywhere(other, server: server) { _ in
                throw APIError.serverUnreachable
            }
        }

        #expect(ids(container) == ["user-a", "user-b"])
        #expect(container.listForgottenUsers(serverID: server.id).isEmpty)
        #expect(container.jellyfinClient.accessToken == "token-user-a")
    }

    @Test func aServerErrorChangesNothing() async throws {
        let container = try signedIn()

        await #expect(throws: APIError.self) {
            try await container.signOutEverywhere(other, server: server) { _ in
                throw APIError.httpError(statusCode: 500, data: nil)
            }
        }

        #expect(ids(container) == ["user-a", "user-b"])
    }

    /// The signed-in profile ends the session with it, through the same path as its plain sign-out.
    @Test func theSignedInProfileEndsTheSession() async throws {
        let container = try signedIn()
        let appState = AppState()
        container.appState = appState
        let before = appState.serverDidSwitch
        let active = try #require(container.listRememberedUsers(serverID: server.id).first { $0.id == "user-a" })

        let outcome = try await container.signOutEverywhere(active, server: server) { _ in }

        #expect(outcome == .endedActiveSession)
        #expect(ids(container) == ["user-b"])
        #expect(container.jellyfinClient.accessToken == nil)
        #expect((try? container.keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))) == nil)
        #expect(appState.serverDidSwitch == before + 1)
    }
}

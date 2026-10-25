import Foundation
import Testing
@testable import Sodalite

/// Audit 2026-09-25, SESSION-3 and SESSION-4. A same-server profile switch cancels nothing, so work
/// that was started for profile A and comes back after the switch to B must see that A is no longer
/// active before it touches the session. Each test switches inside the round trip.
@Suite("Session work that outlives a profile switch", .serialized)
@MainActor
struct ProfileSwitchBoundaryTests {
    private let server = JellyfinServer(
        id: "srv-bnd", name: "Home", internalURL: URL(string: "http://10.0.0.3:8096"), externalURL: nil
    )
    private let seerrServer = SeerrServer(
        id: "seerr-bnd", internalURL: URL(string: "http://10.0.0.3:5055"), externalURL: nil
    )

    private func user(_ id: String, _ name: String) throws -> JellyfinUser {
        try JSONDecoder().decode(
            JellyfinUser.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(name)","ServerId":"srv-bnd"}"#.utf8)
        )
    }

    private var profileB: RememberedUser {
        RememberedUser(id: "user-b", serverID: server.id, name: "Kid", imageTag: nil, token: "token-b")
    }

    /// Signed in as A, with B remembered beside it.
    private func session(http: HookedHTTPClient, passwordForA: String?) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), httpClient: http)
        try container.saveSession(
            server: server, user: try user("user-a", "Parent"), token: "token-a", password: passwordForA
        )
        try container.rememberUser(profileB)
        return container
    }

    private func activeUserSlot(_ container: DependencyContainer) -> String? {
        try? container.keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
    }

    private func isUnreachable(_ check: DependencyContainer.SessionCheck) -> Bool {
        if case .unreachable = check { return true }
        return false
    }

    // MARK: SESSION-4

    /// The stored password would mint A a fresh token, and saving it used to put A back in charge
    /// of the session while the screen showed B.
    @Test func aRefusalForTheLastProfileDoesNotSignItBackIn() async throws {
        let http = HookedHTTPClient()
        http.responses["/Users/AuthenticateByName"] = Data(#"""
        {"User":{"Id":"user-a","Name":"Parent","ServerId":"srv-bnd"},
         "AccessToken":"fresh-a","ServerId":"srv-bnd"}
        """#.utf8)
        let container = try session(http: http, passwordForA: "hunter2")
        http.onRequest["/Users/Me"] = { try? container.switchToUser(profileB, server: server) }

        let check = await container.checkActiveSession()

        #expect(isUnreachable(check))
        #expect(activeUserSlot(container) == "user-b")
        #expect(container.jellyfinClient.accessToken == "token-b")
    }

    /// Same, with the switch landing while the re-login is in flight.
    @Test func aSwitchDuringTheReloginKeepsTheNewProfile() async throws {
        let http = HookedHTTPClient()
        http.responses["/Users/AuthenticateByName"] = Data(#"""
        {"User":{"Id":"user-a","Name":"Parent","ServerId":"srv-bnd"},
         "AccessToken":"fresh-a","ServerId":"srv-bnd"}
        """#.utf8)
        let container = try session(http: http, passwordForA: "hunter2")
        http.onRequest["/Users/AuthenticateByName"] = { try? container.switchToUser(profileB, server: server) }

        let check = await container.checkActiveSession()

        #expect(isUnreachable(check))
        #expect(activeUserSlot(container) == "user-b")
        #expect(container.jellyfinClient.accessToken == "token-b")
        #expect(container.listRememberedUsers(serverID: server.id).map(\.id).sorted() == ["user-a", "user-b"])
    }

    /// Without a password the refusal drops the profile, and the slots it deleted were B's by then.
    @Test func aRefusalForTheLastProfileDoesNotEndTheNewOne() async throws {
        let http = HookedHTTPClient()
        let container = try session(http: http, passwordForA: nil)
        let appState = AppState()
        container.appState = appState
        http.onRequest["/Users/Me"] = { try? container.switchToUser(profileB, server: server) }

        let check = await container.checkActiveSession()

        #expect(isUnreachable(check))
        #expect(activeUserSlot(container) == "user-b")
        #expect(container.jellyfinClient.accessToken == "token-b")
        #expect(appState.rejectedProfileName == nil)
    }

    // MARK: SESSION-3

    private func seerrSession(auth: HookedSeerrAuth) throws -> (DependencyContainer, AppState) {
        let container = try session(http: HookedHTTPClient(), passwordForA: nil)
        container.seerrAuthService = auth
        container.seerrClient.sessionCookie = "cookie-a"
        _ = try container.saveSeerrSession(
            server: seerrServer, forJellyfinUserID: "user-a", jellyfinServerID: server.id
        )
        let appState = AppState()
        container.appState = appState
        appState.setAuthenticated(server: server, user: try user("user-a", "Parent"))
        return (container, appState)
    }

    private func switchToB(_ container: DependencyContainer, _ appState: AppState) {
        try? container.switchToUser(profileB, server: server)
        appState.setAuthenticated(server: server, user: try! user("user-b", "Kid"))
    }

    /// B has no Seerr. A's late answer used to connect B's Catalog as A's Seerr user.
    @Test func aLateConnectionForTheLastProfileIsDropped() async throws {
        let auth = HookedSeerrAuth(result: .success(SeerrUser.stub(id: 1)))
        let (container, appState) = try seerrSession(auth: auth)
        auth.onCurrentUser = { switchToB(container, appState) }

        await container.applySeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: server.id)

        #expect(appState.activeSeerrUser == nil)
    }

    /// B is connected. A's late transport failure used to disconnect it.
    @Test func aLateFailureForTheLastProfileLeavesTheNewConnection() async throws {
        let auth = HookedSeerrAuth(result: .failure(URLError(.timedOut)))
        let (container, appState) = try seerrSession(auth: auth)
        auth.onCurrentUser = {
            switchToB(container, appState)
            appState.setSeerrConnected(server: seerrServer, user: SeerrUser.stub(id: 2))
        }

        await container.applySeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: server.id)

        #expect(appState.activeSeerrUser?.id == 2)
    }

    /// Nothing changed during the round trip: the outcome lands as before.
    @Test func anAnswerForTheStillActiveProfileIsApplied() async throws {
        let auth = HookedSeerrAuth(result: .success(SeerrUser.stub(id: 1)))
        let (container, appState) = try seerrSession(auth: auth)

        await container.applySeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: server.id)

        #expect(appState.activeSeerrUser?.id == 1)
    }

    // MARK: Stubs

    /// Paths without a canned response answer 401. A hook runs once, on the main actor, while the
    /// request for its path is in flight.
    final class HookedHTTPClient: HTTPClientProtocol, @unchecked Sendable {
        var responses: [String: Data] = [:]
        var onRequest: [String: @MainActor @Sendable () -> Void] = [:]

        private func runHook(_ path: String) async {
            if let hook = onRequest.removeValue(forKey: path) { await MainActor.run { hook() } }
        }

        func request<T: Decodable>(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String],
            responseType: T.Type
        ) async throws -> T {
            await runHook(endpoint.path)
            guard let data = responses[endpoint.path] else { throw APIError.unauthorized(message: nil) }
            return try JSONDecoder().decode(T.self, from: data)
        }

        func request(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws {
            await runHook(endpoint.path)
        }

        func requestData(
            baseURL: URL,
            endpoint: APIEndpoint,
            headers: [String: String]
        ) async throws -> (Data, HTTPURLResponse) {
            await runHook(endpoint.path)
            throw APIError.unauthorized(message: nil)
        }
    }

    final class HookedSeerrAuth: SeerrAuthServiceProtocol, @unchecked Sendable {
        let result: Result<SeerrUser, any Error>
        var onCurrentUser: (@MainActor @Sendable () -> Void)?

        init(result: Result<SeerrUser, any Error>) { self.result = result }

        func currentUser() async throws -> SeerrUser {
            if let hook = onCurrentUser {
                onCurrentUser = nil
                await MainActor.run { hook() }
            }
            return try result.get()
        }

        func loginWithJellyfin(username: String, password: String) async throws -> SeerrUser {
            throw APIError.unauthorized(message: nil)
        }

        func loginWithLocal(email: String, password: String) async throws -> SeerrUser {
            throw APIError.unauthorized(message: nil)
        }

        func publicSettings() async throws -> SeerrPublicSettings {
            throw APIError.unauthorized(message: nil)
        }

        func logout() async throws {}
    }
}

private extension SeerrUser {
    static func stub(id: Int) -> SeerrUser {
        try! JSONDecoder().decode(SeerrUser.self, from: Data(#"{"id":\#(id)}"#.utf8))
    }
}

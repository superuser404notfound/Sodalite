import Foundation
import Testing
@testable import Sodalite

/// Records where every request went and with which headers.
final class RecordingHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    struct Sent: Sendable {
        let baseURL: URL
        let path: String
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    var responses: [String: Data] = [:]

    var sent: [Sent] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    private func note(_ baseURL: URL, _ endpoint: APIEndpoint, _ headers: [String: String]) -> Data? {
        lock.lock(); defer { lock.unlock() }
        _sent.append(Sent(baseURL: baseURL, path: endpoint.path, headers: headers))
        return responses[endpoint.path]
    }

    func request<T: Decodable>(
        baseURL: URL, endpoint: APIEndpoint, headers: [String: String], responseType: T.Type
    ) async throws -> T {
        guard let data = note(baseURL, endpoint, headers) else { throw APIError.unauthorized(message: nil) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func request(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws {
        _ = note(baseURL, endpoint, headers)
    }

    func requestData(
        baseURL: URL, endpoint: APIEndpoint, headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        guard let data = note(baseURL, endpoint, headers) else { throw APIError.unauthorized(message: nil) }
        return (data, HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Audit 2026-11-17 NET-201. Every launch, switch and Combine secondary pointed the client at the
/// last address that worked and sent the token before the identity probe had run, so on another
/// network the home LAN address (somebody else's Jellyfin, a router page) got it first.
@Suite("Credentials wait for a LAN address to prove itself", .serialized)
@MainActor
struct CredentialsWaitForVerifiedRouteTests {
    private let serverID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    private let internalURL = URL(string: "http://192.168.178.20:8096")!
    private let externalURL = URL(string: "https://jf.example.com")!
    private let meJSON = Data(#"{"Id":"user-a","Name":"Parent","ServerId":"0f1e2d3c4b5a69788796a5b4c3d2e1f0"}"#.utf8)

    private func user() throws -> JellyfinUser {
        try JSONDecoder().decode(JellyfinUser.self, from: meJSON)
    }

    private func container(
        http: RecordingHTTPClient,
        internalURL: URL?,
        externalURL: URL?,
        lastRoute: ServerRoute = .internal,
        probe: @escaping @Sendable (URL, String) async -> Bool
    ) throws -> DependencyContainer {
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(),
            httpClient: http,
            defaults: UserDefaults(suiteName: "verified-route-\(UUID().uuidString)")!
        )
        container.verifiesServerIdentity = true
        container.jellyfinProbe = probe
        container.serverRouteStore.setLastRoute(lastRoute, serverID: serverID)
        try container.saveSession(
            server: JellyfinServer(id: serverID, name: "Home", internalURL: internalURL, externalURL: externalURL),
            user: try user(),
            token: "token-a-0123456789",
            password: "hunter2"
        )
        return container
    }

    /// The reporter's case: last session at home, this one on a friend's Wi-Fi where the home LAN
    /// address answers as some other server.
    @Test func awayFromHomeTheFirstRequestGoesToTheAddressThatProvedItself() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Users/Me"] = meJSON
        let external = externalURL
        let container = try container(http: http, internalURL: internalURL, externalURL: externalURL) { url, _ in
            url == external
        }
        #expect(container.jellyfinClient.baseURL == internalURL)

        let me = try await container.jellyfinAuthService.getCurrentUser()

        #expect(me.id == "user-a")
        #expect(http.sent.map(\.baseURL) == [externalURL])
        #expect(container.jellyfinClient.baseURL == externalURL)
    }

    /// At home the LAN address still wins, and the request waits only for its probe.
    @Test func atHomeTheLANAddressIsUsedOnceItAnswers() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Users/Me"] = meJSON
        let container = try container(http: http, internalURL: internalURL, externalURL: externalURL) { _, _ in true }

        _ = try await container.jellyfinAuthService.getCurrentUser()

        #expect(http.sent.map(\.baseURL) == [internalURL])
    }

    /// A LAN-only server whose address does not prove itself gets no request, so no token, at all.
    @Test func anUnprovedLANAddressGetsNothing() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Users/Me"] = meJSON
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in false }

        await #expect(throws: APIError.self) {
            _ = try await container.jellyfinAuthService.getCurrentUser()
        }
        #expect(http.sent.isEmpty)
    }

    /// Artwork URLs carry the token in their query; before the proof they are built without it.
    @Test func artworkCarriesNoTokenBeforeTheProof() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in true }

        let early = try #require(container.jellyfinImageService.imageURL(itemID: "item", tag: "t"))
        #expect(!early.absoluteString.contains("token-a"))

        await container.routeResolveTask?.value
        let later = try #require(container.jellyfinImageService.imageURL(itemID: "item", tag: "t"))
        #expect(later.absoluteString.contains("api_key=token-a-0123456789"))
    }

    // MARK: NET-202

    /// Audit 2026-11-17 NET-202. A 401 from an address that does not answer as this server is not
    /// the server's verdict: the stored password stays home and the profile stays on every device.
    @Test func aRefusalFromAnAddressThatIsNotTheServerKeepsTheProfile() async throws {
        let http = RecordingHTTPClient()
        let probes = ProbeCounter()
        // Proves itself for the route pass, then a stranger answers there by the time of the 401.
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in
            await probes.next() == 1
        }
        await container.routeResolveTask?.value

        let check = await container.checkActiveSession()

        if case .unreachable = check {} else { Issue.record("expected unreachable, got \(check)") }
        #expect(!http.sent.contains { $0.path == "/Users/AuthenticateByName" })
        #expect(container.listRememberedUsers(serverID: serverID).map(\.id) == ["user-a"])
        #expect(container.listForgottenUsers(serverID: serverID).isEmpty)
        #expect(container.jellyfinClient.accessToken == "token-a-0123456789")
    }

    /// The real server's refusal still ends the profile.
    @Test func aRefusalFromTheServerItselfStillCounts() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in true }
        await container.routeResolveTask?.value

        let check = await container.checkActiveSession()

        if case .rejected = check {} else { Issue.record("expected rejected, got \(check)") }
        #expect(http.sent.contains { $0.path == "/Users/AuthenticateByName" && $0.baseURL == internalURL })
        #expect(container.listRememberedUsers(serverID: serverID).isEmpty)
    }

    /// Seerr cannot be asked who it is, so a refusal from its LAN slot counts only on the proved
    /// home network.
    @Test func aSeerrRefusalOffTheHomeNetworkKeepsTheSession() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: nil, externalURL: externalURL) { _, _ in true }
        await container.routeResolveTask?.value
        let seerr = SeerrServer(id: "seerr-1", internalURL: URL(string: "http://192.168.178.20:5055"), externalURL: nil)
        container.seerrClient.sessionCookie = "cookie-a"
        try container.saveSeerrSession(server: seerr, forJellyfinUserID: "user-a", jellyfinServerID: serverID)
        container.seerrAuthService = ProfileSwitchBoundaryTests.HookedSeerrAuth(
            result: .failure(APIError.unauthorized(message: nil)))

        let outcome = await container.syncSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID)

        if case .transientFailure = outcome {} else { Issue.record("expected transientFailure, got \(outcome)") }
        #expect(container.restoreSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID) != nil)
    }

    /// A two-slot Seerr starts on its public slot until Jellyfin's LAN address proves this is home.
    @Test func aTwoSlotSeerrStartsOnItsPublicSlot() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in false }
        let seerr = SeerrServer(
            id: "seerr-2",
            internalURL: URL(string: "http://192.168.178.20:5055"),
            externalURL: URL(string: "https://requests.example.com")
        )
        container.serverRouteStore.setLastRoute(.internal, serverID: container.seerrRouteKey(seerr.id))

        #expect(container.preferredSeerrURL(for: seerr) == seerr.externalURL)
        container.isOnVerifiedHomeNetwork = true
        #expect(container.preferredSeerrURL(for: seerr) == seerr.internalURL)
    }
}

@MainActor
final class URLBox {
    var url: URL
    init(_ url: URL) { self.url = url }
}

actor ProbeCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// The gate on its own: which requests wait, which go, and which are refused.
@Suite("Route gate")
@MainActor
struct RouteGateTests {
    private let lan = URL(string: "http://10.0.0.5:8096")!
    private let wan = URL(string: "https://jf.example.com")!

    @Test func aPublicAddressNeverWaits() async throws {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        #expect(try await gate.admit { wan } == wan)
    }

    @Test func aLANAddressWaitsForItsProof() async throws {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        let epoch = gate.epoch
        let lan = lan
        let admitted = Task { try await gate.admit { lan } }
        await Task.yield()
        gate.record(lan, answered: true, epoch: epoch)
        #expect(try await admitted.value == lan)
    }

    @Test func aLANAddressThatNeverProvedItselfIsRefusedOnceSettled() async throws {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        let lan = lan
        let admitted = Task { try await gate.admit { lan } }
        await Task.yield()
        gate.settle(epoch: gate.epoch)
        await #expect(throws: APIError.self) { _ = try await admitted.value }
    }

    @Test func aProofFromBeforeTheNetworkChangedDoesNotCount() async throws {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        let old = gate.epoch
        gate.reset()
        gate.record(lan, answered: true, epoch: old)
        #expect(!gate.allows(lan))
    }

    @Test func aHeldRequestFollowsTheAddressTheResolveMovedTo() async throws {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        let current = URLBox(lan)
        let admitted = Task { try await gate.admit { current.url } }
        await Task.yield()
        current.url = wan
        gate.settle(epoch: gate.epoch)
        #expect(try await admitted.value == wan)
    }

    @Test func aCancelledRequestStopsWaiting() async throws {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        let lan = lan
        let admitted = Task { try await gate.admit { lan } }
        await Task.yield()
        admitted.cancel()
        await #expect(throws: CancellationError.self) { _ = try await admitted.value }
    }

    @Test func anUnenforcedGateLetsEverythingThrough() async throws {
        let gate = RouteGate(isEnforced: false)
        gate.reset()
        #expect(try await gate.admit { lan } == lan)
    }
}

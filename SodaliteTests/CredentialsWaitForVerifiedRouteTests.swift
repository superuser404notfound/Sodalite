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
        // No reading is not evidence; the tests that need one set it.
        container.currentPathReading = { nil }
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
        // Proves itself for the route pass, then a stranger answers there by the time of the 401.
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in true }
        await container.routeResolveTask?.value
        container.jellyfinIdentity = { _, _ in .otherServer }

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

    private func lanSeerrSession(
        _ container: DependencyContainer, auth: ProfileSwitchBoundaryTests.HookedSeerrAuth
    ) throws {
        let seerr = SeerrServer(id: "seerr-1", internalURL: URL(string: "http://192.168.178.20:5055"), externalURL: nil)
        container.seerrClient.sessionCookie = "cookie-a"
        try container.saveSeerrSession(server: seerr, forJellyfinUserID: "user-a", jellyfinServerID: serverID)
        container.seerrAuthService = auth
    }

    /// Seerr cannot be asked who it is. Off the proved home network its LAN address gets no cookie
    /// at all, and the session is kept for a later try (audit review R-ROUTE-8).
    @Test func aLANSeerrOffTheHomeNetworkGetsNoCookie() async throws {
        let http = RecordingHTTPClient()
        let external = externalURL
        let container = try container(http: http, internalURL: internalURL, externalURL: externalURL) { url, _ in
            url == external
        }
        await container.routeResolveTask?.value
        let auth = ProfileSwitchBoundaryTests.HookedSeerrAuth(result: .failure(APIError.unauthorized(message: nil)))
        let asked = Flag()
        auth.onCurrentUser = { asked.value = true }
        try lanSeerrSession(container, auth: auth)

        let outcome = await container.syncSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID)

        if case .transientFailure = outcome {} else { Issue.record("expected transientFailure, got \(outcome)") }
        #expect(!asked.value)
        #expect(container.restoreSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID) != nil)
    }

    /// With Jellyfin on a public name only there is no home network to prove, so a genuine Seerr
    /// refusal still ends the session instead of being kept forever (audit review R-ROUTE-8).
    @Test func withoutAJellyfinLANSlotASeerrRefusalStillCounts() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: nil, externalURL: externalURL) { _, _ in true }
        let home = Self.reading(subnet: "192.168.178.40")
        container.currentPathReading = { home }
        await container.routeResolveTask?.value
        try lanSeerrSession(container, auth: ProfileSwitchBoundaryTests.HookedSeerrAuth(
            result: .failure(APIError.unauthorized(message: nil))))

        let outcome = await container.syncSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID)

        if case .invalidated = outcome {} else { Issue.record("expected invalidated, got \(outcome)") }
    }

    /// Audit review R-ROUTE-25: the same Seerr refusal on a network it never answered from (here
    /// cellular) is anybody's, so the session stays and no cookie goes there.
    @Test func withoutAJellyfinLANSlotAnOffNetworkSeerrRefusalKeepsTheSession() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: nil, externalURL: externalURL) { _, _ in true }
        container.currentPathReading = { NetworkPathSnapshot.Reading(isSatisfied: true, usesLocalInterface: false, hasLocalInterface: false) }
        await container.routeResolveTask?.value
        try lanSeerrSession(container, auth: ProfileSwitchBoundaryTests.HookedSeerrAuth(
            result: .failure(APIError.unauthorized(message: nil))))

        let outcome = await container.syncSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID)

        if case .transientFailure = outcome {} else { Issue.record("expected transientFailure, got \(outcome)") }
        #expect(container.restoreSeerrSession(forJellyfinUserID: "user-a", jellyfinServerID: serverID) != nil)
    }

    /// Audit review R-ROUTE-23: Catalog's own requests are held the same way, not only the sync.
    @Test func catalogRequestsToAnUntrustedLANSeerrAreRefused() async throws {
        let http = RecordingHTTPClient()
        let external = externalURL
        let container = try container(http: http, internalURL: internalURL, externalURL: externalURL) { url, _ in
            url == external
        }
        await container.routeResolveTask?.value
        let seerrURL = try #require(URL(string: "http://192.168.178.20:5055"))
        let hold = try #require(container.seerrClient.routeHold)

        await #expect(throws: APIError.self) { _ = try await hold { seerrURL } }
    }

    static func reading(subnet ip: String) -> NetworkPathSnapshot.Reading {
        NetworkPathSnapshot.Reading(
            isSatisfied: true, usesLocalInterface: true, hasLocalInterface: true,
            subnets: [LocalSubnet(address: LocalSubnet.parseIPv4(ip)!, mask: 0xFFFF_FF00)]
        )
    }

    // MARK: Audit review R-ROUTE-21, R-ROUTE-22, R-ROUTE-24

    /// Off the server's network the patient identity check is skipped, so a held request is
    /// refused at the route cap instead of after eight more seconds.
    @Test func offNetworkTheGateSettlesWithinTheRouteCap() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in false }
        container.currentPathReading = { NetworkPathSnapshot.Reading(isSatisfied: true, usesLocalInterface: false, hasLocalInterface: false) }
        let askedPatiently = Flag()
        container.jellyfinIdentity = { _, _ in
            await MainActor.run { askedPatiently.value = true }
            try? await Task.sleep(for: .seconds(30))
            return .noAnswer
        }
        let started = ContinuousClock.now

        await #expect(throws: APIError.self) {
            _ = try await container.jellyfinAuthService.getCurrentUser()
        }

        #expect(!askedPatiently.value)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(http.sent.isEmpty)
    }

    /// A server that was down when the epoch settled and answers later gets its LAN back on the
    /// next pass, without waiting for a network change.
    @Test func aLaterPassCanStillProveTheAddress() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Users/Me"] = meJSON
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in false }
        await container.routeResolveTask?.value
        await #expect(throws: APIError.self) {
            _ = try await container.jellyfinAuthService.getCurrentUser()
        }

        container.jellyfinIdentity = { _, _ in .matches }
        await container.scheduleRouteResolve().value

        _ = try await container.jellyfinAuthService.getCurrentUser()
        #expect(http.sent.map(\.baseURL) == [internalURL])
    }

    /// A login screen left open across a network change does not keep the old network's proof.
    @Test func aSignInClientLosesItsProofOnAPathChange() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in true }
        let server = try #require(container.listKnownServers().first)
        let client = container.makeSignInClient(for: server)
        _ = await container.resolveSignInRoute(for: server, client: client)
        let gate = try #require(client.routeGate)
        #expect(gate.allows(internalURL))

        NotificationCenter.default.post(name: .networkPathWillChange, object: nil)

        #expect(!gate.allows(internalURL))
        _ = await container.resolveSignInRoute(for: server, client: client)
        #expect(gate.allows(internalURL))
    }

    // MARK: Audit review R-ROUTE-1 and R-ROUTE-3

    /// The route probe's cap missed, but the patient identity check answers: the session keeps
    /// its LAN requests.
    @Test func aSlowIdentityAnswerStillAdmits() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Users/Me"] = meJSON
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in false }
        container.jellyfinIdentity = { _, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return .matches
        }

        _ = try await container.jellyfinAuthService.getCurrentUser()

        #expect(http.sent.map(\.baseURL) == [internalURL])
    }

    /// A server whose readiness endpoint answers 5xx (booting, a proxy in front) is still this
    /// server: the verdict may say so, but its requests go out (Sodalite#199).
    @Test func readiness5xxWithTheRightIdentityAdmits() async throws {
        let http = RecordingHTTPClient()
        http.responses["/Users/Me"] = meJSON
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in true }
        container.jellyfinAnswer = { _, _ in ServerProbe.Answer(identity: .matches, isReady: false) }
        container.jellyfinIdentity = { _, _ in .noAnswer }

        _ = try await container.jellyfinAuthService.getCurrentUser()

        #expect(http.sent.map(\.baseURL) == [internalURL])
    }

    /// A path change takes the old network's proof back at once, before the debounced resolve.
    @Test func aPathChangeTakesTheProofBackAtOnce() async throws {
        let http = RecordingHTTPClient()
        let container = try container(http: http, internalURL: internalURL, externalURL: nil) { _, _ in true }
        await container.routeResolveTask?.value
        let gate = try #require(container.jellyfinClient.routeGate)
        #expect(gate.allows(internalURL))

        NotificationCenter.default.post(name: .networkPathWillChange, object: nil)

        #expect(!gate.allows(internalURL))
        await container.routeResolveTask?.value
        #expect(gate.allows(internalURL))
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
final class Flag {
    var value = false
}

@MainActor
final class URLBox {
    var url: URL
    init(_ url: URL) { self.url = url }
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
        gate.record(lan, identity: .matches, epoch: epoch)
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
        gate.record(lan, identity: .matches, epoch: old)
        #expect(!gate.allows(lan))
    }

    /// Audit review R-ROUTE-1: silence (a timeout, a busy server) keeps a proof; only an answer
    /// naming another server takes it back.
    @Test func onlyAnotherServerRevokesAProof() {
        let gate = RouteGate(isEnforced: true)
        gate.reset()
        gate.record(lan, identity: .matches, epoch: gate.epoch)
        gate.record(lan, identity: .noAnswer, epoch: gate.epoch)
        #expect(gate.allows(lan))
        gate.record(lan, identity: .otherServer, epoch: gate.epoch)
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

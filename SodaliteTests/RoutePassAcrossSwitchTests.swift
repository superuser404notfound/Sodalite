import Foundation
import Testing
@testable import Sodalite

/// Holds a probe until the test lets it go, then lets every later probe through at once.
actor ProbeLatch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func pass() async {
        entered += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Audit 2026-11-17 SHELL-201 / SHELL-R202. The recheck watch, the transport re-check and Try Again
/// ran their route pass outside the one task a switch cancels, and the pass wrote whatever server it
/// had captured into the live client. A pass for server A that finished after a switch to B put A's
/// address next to B's token and A's verdict on B's screen.
@Suite("A route pass outlived by a server switch", .serialized)
@MainActor
struct RoutePassAcrossSwitchTests {
    private let serverA = JellyfinServer(
        id: "srv-a", name: "A", internalURL: URL(string: "http://10.0.0.1:8096"), externalURL: nil)
    private let serverB = JellyfinServer(
        id: "srv-b", name: "B", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil)

    private func user(_ id: String, server: String) throws -> JellyfinUser {
        try JSONDecoder().decode(
            JellyfinUser.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","ServerId":"\#(server)"}"#.utf8)
        )
    }

    @Test func aPassForThePreviousServerWritesNothingAfterTheSwitch() async throws {
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(),
            defaults: UserDefaults(suiteName: "route-switch-\(UUID().uuidString)")!
        )
        let appState = AppState()
        container.appState = appState
        container.jellyfinProbe = { _, _ in true }

        try container.addServer(serverB)
        try container.keychainService.save("token-b", for: KeychainKeys.accessToken(serverID: serverB.id))
        try container.keychainService.save("user-b", for: KeychainKeys.userID(serverID: serverB.id))
        try container.saveSession(server: serverA, user: try user("user-a", server: serverA.id), token: "token-a")
        await container.routeResolveTask?.value

        // From here A's address hangs, the way a dead or foreign one does for two seconds.
        let latch = ProbeLatch()
        let urlA = try #require(serverA.internalURL), urlB = try #require(serverB.internalURL)
        container.jellyfinProbe = { url, _ in
            if url == urlA {
                await latch.pass()
                return false
            }
            return url == urlB
        }

        // What the watch, a failed request or Try Again starts.
        let stale = Task { await container.resolveActiveRoutes() }
        while await latch.entered == 0 { await Task.yield() }

        try container.switchServer(to: serverB.id)
        await container.routeResolveTask?.value
        #expect(container.jellyfinClient.baseURL == urlB)
        #expect(appState.serverReachability == .reachable)

        await latch.open()
        await stale.value

        #expect(container.jellyfinClient.baseURL == urlB)
        #expect(container.jellyfinClient.accessToken == "token-b")
        #expect(appState.serverReachability == .reachable)
    }

    /// Try Again waits for the pass it started, so the reload it raises reads the new verdict.
    @Test func tryAgainAwaitsTheOnePass() async throws {
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(),
            defaults: UserDefaults(suiteName: "route-retry-\(UUID().uuidString)")!
        )
        let appState = AppState()
        container.appState = appState
        container.jellyfinProbe = { _, _ in true }
        try container.saveSession(server: serverA, user: try user("user-a", server: serverA.id), token: "token-a")

        await container.retryAfterFailure()

        #expect(appState.serverReachability == .reachable)
        #expect(appState.requestContentReload == 1)
    }
}

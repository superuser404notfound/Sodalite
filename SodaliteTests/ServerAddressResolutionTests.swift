import Foundation
import Testing
@testable import Sodalite

/// Sodalite#83: the setup screens accept a bare address and let discovery work out scheme and port,
/// so the URL editors have to accept the same text instead of demanding a scheme.
@Suite("Server address resolution")
struct ServerAddressResolutionTests {
    private let resolved = URL(string: "http://192.168.1.10:5055")!

    private func discovery(
        answers: [String: URL],
        delay: Duration = .zero
    ) -> @Sendable (String) async -> URL? {
        { input in
            try? await Task.sleep(for: delay)
            return answers[input]
        }
    }

    @Test("a bare address is resolved to what answered")
    func bareAddressResolves() async {
        let outcome = await ServerAddressResolution.resolve(
            "192.168.1.10",
            discover: discovery(answers: ["192.168.1.10": resolved])
        )
        #expect(outcome == .resolved(resolved))
    }

    @Test("surrounding whitespace reaches discovery trimmed")
    func trimsBeforeDiscovery() async {
        let outcome = await ServerAddressResolution.resolve(
            "  192.168.1.10\n",
            discover: discovery(answers: ["192.168.1.10": resolved])
        )
        #expect(outcome == .resolved(resolved))
    }

    @Test("an empty field clears the slot rather than failing")
    func emptyIsASlot() async {
        #expect(await ServerAddressResolution.resolve("", discover: discovery(answers: [:])) == .empty)
        #expect(await ServerAddressResolution.resolve("   ", discover: discovery(answers: [:])) == .empty)
    }

    /// The slot being edited may live on a network this device cannot see right now, so a complete
    /// URL survives a silent discovery and lands on the save-anyway path.
    @Test("a complete URL nobody answers stays savable")
    func unreachableCompleteURL() async {
        let outcome = await ServerAddressResolution.resolve(
            "https://jellyseerr.example.com",
            discover: discovery(answers: [:])
        )
        #expect(outcome == .unreachable(URL(string: "https://jellyseerr.example.com")!))
    }

    /// Without a scheme there is nothing to save unverified: which of the four candidates the
    /// address meant is exactly what discovery failed to establish.
    @Test("a bare address nobody answers cannot be saved unverified")
    func unresolvedBareAddress() async {
        #expect(await ServerAddressResolution.resolve("192.168.1.10", discover: discovery(answers: [:])) == .unresolved)
        #expect(await ServerAddressResolution.resolve("seerr.example.com:5055", discover: discovery(answers: [:])) == .unresolved)
    }

    @Test("discovery past the budget is treated as no answer")
    func budgetBoundsTheWait() async {
        let outcome = await ServerAddressResolution.resolve(
            "http://192.168.1.10:5055",
            budget: .milliseconds(50),
            discover: discovery(answers: ["http://192.168.1.10:5055": resolved], delay: .seconds(30))
        )
        #expect(outcome == .unreachable(resolved))
    }

    @Test("only http and https can be saved without an answer")
    func completeURLNeedsASchemeWeSpeak() {
        #expect(ServerAddressResolution.completeURL("http://192.168.1.10:8096") != nil)
        #expect(ServerAddressResolution.completeURL("HTTPS://jellyfin.example.com") != nil)
        #expect(ServerAddressResolution.completeURL(" http://192.168.1.10/jellyfin ") != nil)
        #expect(ServerAddressResolution.completeURL("ftp://192.168.1.10") == nil)
        #expect(ServerAddressResolution.completeURL("192.168.1.10:8096") == nil)
        #expect(ServerAddressResolution.completeURL("http://") == nil)
        #expect(ServerAddressResolution.completeURL("jellyfin.example.com") == nil)
    }

    // MARK: Audit 2026-11-17 ASD-204

    private struct StubDiscovery: ServerDiscoveryServiceProtocol {
        let serverID: String
        func discoverServer(input: String) async -> ServerDiscoveryResult {
            .success(
                url: URL(string: "http://\(input):8096")!,
                serverInfo: ServerDiscoveryInfo(id: serverID, serverName: "Jellyfin", version: "10.11")
            )
        }
    }

    @Test("an address that answers as another Jellyfin is not this server's")
    func anotherServerIsRefused() async {
        let discover = ServerAddressResolution.jellyfin(
            StubDiscovery(serverID: "ffffffffffffffffffffffffffffffff"),
            expectedServerID: "0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        let outcome = await ServerAddressResolution.resolve("192.168.1.20", discover: discover)
        #expect(outcome == .otherServer(URL(string: "http://192.168.1.20:8096")!))
    }

    @Test("the same server is accepted however its id is written")
    func sameServerIsAccepted() async {
        let discover = ServerAddressResolution.jellyfin(
            StubDiscovery(serverID: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"),
            expectedServerID: "0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        let outcome = await ServerAddressResolution.resolve("192.168.1.20", discover: discover)
        #expect(outcome == .resolved(URL(string: "http://192.168.1.20:8096")!))
    }
}


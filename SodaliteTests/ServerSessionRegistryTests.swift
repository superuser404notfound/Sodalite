import Foundation
import Testing
@testable import Sodalite

@Suite(.serialized)
@MainActor
struct ServerSessionRegistryTests {
    private func server(_ id: String, _ url: String) -> JellyfinServer {
        JellyfinServer(id: id, name: id, internalURL: URL(string: url), externalURL: nil)
    }

    private func makeRegistry() -> (ServerSessionRegistry, JellyfinClient) {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        live.baseURL = URL(string: "http://a.lan:8096")
        live.accessToken = "tok-a"
        return (ServerSessionRegistry(activeClient: live, httpClient: http), live)
    }

    private func candidate(_ id: String, _ url: String, user: String = "u-b", token: String = "tok-b") -> ParticipantCandidate {
        ParticipantCandidate(server: server(id, url), credential: SessionCredential(userID: user, token: token))
    }

    @Test func offMeansOnlyTheActiveSession() {
        let (registry, _) = makeRegistry()
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"), secondaries: [], baseURL: { $0.url })
        #expect(registry.participants.count == 1)
        #expect(registry.participants.first === registry.active)
        #expect(registry.active.userID == "u-a")
    }

    @Test func secondariesGetTheirOwnClient() {
        let (registry, live) = makeRegistry()
        registry.apply(
            active: (server("a", "http://a.lan:8096"), "u-a"),
            secondaries: [candidate("b", "http://b.lan:8096")],
            baseURL: { $0.url })
        let session = registry.session(forServerID: "b")
        #expect(session.client !== live)
        #expect(session.client.accessToken == "tok-b")
        #expect(session.client.baseURL == URL(string: "http://b.lan:8096"))
        #expect(session.userID == "u-b")
        #expect(!session.isActive)
    }

    @Test func unknownOrMissingServerFallsBackToActive() throws {
        let (registry, _) = makeRegistry()
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"), secondaries: [], baseURL: { $0.url })
        #expect(registry.session(forServerID: nil) === registry.active)
        #expect(registry.session(forServerID: "zzz") === registry.active)
        let item = try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"i","Name":"n","Type":"Movie"}"#.utf8))
        #expect(registry.session(for: item) === registry.active)
    }

    @Test func unchangedSetReusesSessionsAndKeepsTheRevision() {
        let (registry, _) = makeRegistry()
        let b = candidate("b", "http://b.lan:8096")
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"), secondaries: [b], baseURL: { $0.url })
        let first = registry.session(forServerID: "b")
        let revision = registry.participantsRevision
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"), secondaries: [b], baseURL: { $0.url })
        #expect(registry.session(forServerID: "b") === first)
        #expect(registry.participantsRevision == revision)
    }

    @Test func aChangedUserRebuildsTheSessionAndBumpsTheRevision() {
        let (registry, _) = makeRegistry()
        let a = server("a", "http://a.lan:8096")
        registry.apply(active: (a, "u-a"), secondaries: [candidate("b", "http://b.lan:8096", token: "t1")], baseURL: { $0.url })
        let first = registry.session(forServerID: "b")
        let revision = registry.participantsRevision
        registry.apply(active: (a, "u-a"), secondaries: [candidate("b", "http://b.lan:8096", user: "u-b2", token: "t2")], baseURL: { $0.url })
        #expect(registry.session(forServerID: "b") !== first)
        #expect(registry.participantsRevision != revision)
    }

    @Test func mutedServerLeavesTheParticipants() {
        let (registry, _) = makeRegistry()
        let b = candidate("b", "http://b.lan:8096")
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"), secondaries: [b], baseURL: { $0.url })
        let revision = registry.participantsRevision
        registry.mute(serverID: "b")
        #expect(registry.participants.count == 1)
        #expect(registry.participantsRevision != revision)
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"), secondaries: [b], baseURL: { $0.url })
        #expect(registry.participants.count == 1)
    }

    @Test func secondaryTokensReachTheLogRedactor() {
        let (registry, _) = makeRegistry()
        registry.apply(
            active: (server("a", "http://a.lan:8096"), "u-a"),
            secondaries: [candidate("b", "http://b.lan:8096", token: "secretb7f3k29q")],
            baseURL: { $0.url })
        #expect(!LogRedaction.redact("token secretb7f3k29q leaked").contains("secretb7f3k29q"))
    }
}

/// The container side: who takes part follows the profile's switch and the keychain, and stays put
/// when nothing changed.
@Suite(.serialized)
@MainActor
struct ContainerSessionRegistryTests {
    private let serverA = JellyfinServer(id: "srv-a", name: "A", internalURL: URL(string: "http://a.lan:8096"), externalURL: nil)
    private let serverB = JellyfinServer(id: "srv-b", name: "B", internalURL: URL(string: "http://b.lan:8096"), externalURL: nil)

    private func user(_ id: String, server: String) throws -> JellyfinUser {
        try JSONDecoder().decode(JellyfinUser.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)","ServerId":"\#(server)"}"#.utf8))
    }

    /// Signed in to B first, then A, so A is active and B holds a device token slot.
    private func twoServers() throws -> DependencyContainer {
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(), defaults: UserDefaults(suiteName: "reg-\(UUID().uuidString)")!)
        try container.saveSession(server: serverB, user: try user("u-b", server: "srv-b"), token: "tok-b")
        try container.saveSession(server: serverA, user: try user("u-a", server: "srv-a"), token: "tok-a")
        return container
    }

    @Test func offByDefault() throws {
        let container = try twoServers()
        #expect(container.sessionRegistry.participants.count == 1)
        #expect(container.sessionRegistry.active.server?.id == "srv-a")
        #expect(container.sessionRegistry.active.userID == "u-a")
    }

    @Test func enablingForTheActiveProfileBringsTheOtherServerIn() throws {
        let container = try twoServers()
        container.combinedServers.setEnabled(true, scope: ProfileKey(serverID: "srv-a", userID: "u-a").storageScope)
        container.refreshSessionRegistry()
        #expect(container.sessionRegistry.participants.map { $0.server?.id } == ["srv-a", "srv-b"])
        #expect(container.sessionRegistry.session(forServerID: "srv-b").userID == "u-b")
    }

    @Test func removingTheSecondaryDropsItsSession() throws {
        let container = try twoServers()
        container.combinedServers.setEnabled(true, scope: ProfileKey(serverID: "srv-a", userID: "u-a").storageScope)
        container.refreshSessionRegistry()
        try container.removeServer(id: "srv-b")
        #expect(container.sessionRegistry.participants.count == 1)
    }
}

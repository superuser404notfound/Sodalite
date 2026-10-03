import Foundation
import Testing
@testable import Sodalite

@MainActor
struct ServerActivationStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "activation-\(UUID().uuidString)")!
    }

    @Test func stampsAndReadsBack() {
        var clock = Date(timeIntervalSince1970: 100)
        let store = ServerActivationStore(defaults: defaults(), now: { clock })
        store.stamp(serverID: "a")
        clock = Date(timeIntervalSince1970: 200)
        store.stamp(serverID: "b")
        #expect(store.lastActivated(serverID: "a") == Date(timeIntervalSince1970: 100))
        #expect(store.lastActivated(serverID: "b") == Date(timeIntervalSince1970: 200))
        #expect(store.lastActivated(serverID: "c") == nil)
    }

    @Test func survivesANewInstanceOnTheSameDefaults() {
        let suite = defaults()
        ServerActivationStore(defaults: suite, now: { Date(timeIntervalSince1970: 5) }).stamp(serverID: "a")
        #expect(ServerActivationStore(defaults: suite).lastActivated(serverID: "a") == Date(timeIntervalSince1970: 5))
    }

    @Test func forgetDropsTheServer() {
        let store = ServerActivationStore(defaults: defaults())
        store.stamp(serverID: "a")
        store.forget(serverID: "a")
        #expect(store.lastActivated(serverID: "a") == nil)
    }

    @Test func signingInStampsTheServer() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults())
        let server = JellyfinServer(id: "srv-a", name: "A", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil)
        let user = try JSONDecoder().decode(
            JellyfinUser.self, from: Data(#"{"Id":"u1","Name":"V","ServerId":"srv-a"}"#.utf8))
        try container.saveSession(server: server, user: user, token: "t1")
        #expect(container.serverActivation.lastActivated(serverID: "srv-a") != nil)
    }

    @Test func removingTheServerForgetsIt() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults())
        let server = JellyfinServer(id: "srv-a", name: "A", internalURL: URL(string: "http://10.0.0.2:8096"), externalURL: nil)
        let user = try JSONDecoder().decode(
            JellyfinUser.self, from: Data(#"{"Id":"u1","Name":"V","ServerId":"srv-a"}"#.utf8))
        try container.saveSession(server: server, user: user, token: "t1")
        try container.removeServer(id: "srv-a")
        #expect(container.serverActivation.lastActivated(serverID: "srv-a") == nil)
    }
}

import Foundation
import Testing
@testable import Sodalite

@Suite(.serialized)
@MainActor
struct CombinedServersSettingsTests {
    private let serverA = JellyfinServer(id: "srv-a", name: "A", internalURL: URL(string: "http://a.lan:8096"), externalURL: nil)
    private let serverB = JellyfinServer(id: "srv-b", name: "B", internalURL: URL(string: "http://b.lan:8096"), externalURL: nil)

    private func user(_ id: String, server: String) throws -> JellyfinUser {
        try JSONDecoder().decode(JellyfinUser.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)-name","ServerId":"\#(server)"}"#.utf8))
    }

    private func twoServers() throws -> DependencyContainer {
        let container = DependencyContainer(
            keychainService: InMemoryKeychain(), defaults: UserDefaults(suiteName: "cs-\(UUID().uuidString)")!)
        try container.saveSession(server: serverB, user: try user("u-b", server: "srv-b"), token: "tok-b")
        try container.saveSession(server: serverA, user: try user("u-a", server: "srv-a"), token: "tok-a")
        return container
    }

    @Test func switchingOnBringsTheOtherServerInAndAnnouncesIt() async throws {
        let container = try twoServers()
        nonisolated(unsafe) var notified = 0
        let token = NotificationCenter.default.addObserver(forName: .homeConfigDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        container.setCombiningServers(true)
        #expect(container.isCombiningServers())
        #expect(container.sessionRegistry.participants.count == 2)
        #expect(notified == 1)
    }

    @Test func excludingAServerTakesItOut() throws {
        let container = try twoServers()
        container.setCombiningServers(true)
        container.setServer("srv-b", combined: false)
        #expect(container.sessionRegistry.participants.count == 1)
        #expect(container.combinedServerStatus(serverB) == .excluded(userName: "u-b-name"))
        container.setServer("srv-b", combined: true)
        #expect(container.combinedServerStatus(serverB) == .contributes(userName: "u-b-name"))
        #expect(container.combinedServerStatus(serverA) == .active)
    }

    @Test func aServerWithoutASessionSaysSo() throws {
        let container = try twoServers()
        let serverC = JellyfinServer(id: "srv-c", name: "C", internalURL: URL(string: "http://c.lan:8096"), externalURL: nil)
        #expect(container.combinedServerStatus(serverC) == .noSession)
    }

    /// Audit 2026-11-17 SYNC-201: which account a second server contributes is decided per device, so
    /// the switch and its exclusions stay on the box that set them. A record still decodes and applies
    /// without them, and one from a build that did send them changes nothing here.
    @Test func combineServersNeverTravelsThroughTheHomeRecord() throws {
        let scope = "srv-x:u-\(UUID().uuidString)"
        let prefs = CombinedServersPreferences(defaults: .standard)
        prefs.setEnabled(true, scope: scope)
        prefs.setExcluded(["srv-q"], scope: scope)
        defer { prefs.setEnabled(false, scope: scope); prefs.setExcluded([], scope: scope) }
        var payload = ProfileHomeStore.collect(scope: scope, stamp: .now)
        #expect(payload.combineServers == nil)
        #expect(payload.combineServersExcluded == nil)

        let old = #"{"schemaVersion":1,"updatedAt":0,"mergeCWNextUp":false,"rewatchNextUp":false,"collectionGrouping":"server","librarySorts":{}}"#
        let decoded = try JSONDecoder().decode(ProfileHomePayload.self, from: Data(old.utf8))
        #expect(decoded.combineServers == nil)

        // A record from a build that did send the switch: Alice's iPhone, applied on a box where the
        // second server is signed in as someone else.
        payload.combineServers = true
        payload.combineServersExcluded = ["srv-q"]
        let target = "srv-y:u-\(UUID().uuidString)"
        defer { prefs.setEnabled(false, scope: target); prefs.setExcluded([], scope: target) }
        ProfileHomeStore.apply(payload, scope: target)
        #expect(!prefs.isEnabled(scope: target))
        #expect(prefs.excludedServerIDs(scope: target).isEmpty)

        // A switch already on here is not turned off by a record that carries none.
        prefs.setEnabled(true, scope: target)
        payload.combineServers = false
        ProfileHomeStore.apply(payload, scope: target)
        #expect(prefs.isEnabled(scope: target))
    }
}

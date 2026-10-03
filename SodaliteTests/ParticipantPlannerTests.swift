import Foundation
import Testing
@testable import Sodalite

@Suite(.serialized)
@MainActor
struct ParticipantPlannerTests {
    private func server(_ id: String) -> JellyfinServer {
        JellyfinServer(id: id, name: id.uppercased(), internalURL: URL(string: "http://\(id).lan:8096"), externalURL: nil)
    }
    private let anyCredential: (String) -> SessionCredential? = { SessionCredential(userID: "u-\($0)", token: "t-\($0)") }

    @Test func offMeansNoSecondaries() {
        let plan = ParticipantPlanner.plan(
            servers: [server("a"), server("b")], activeServerID: "a", enabled: false,
            excluded: [], lastActivated: [:], credential: anyCredential)
        #expect(plan.isEmpty)
    }

    @Test func activeIsNeverASecondary() {
        let plan = ParticipantPlanner.plan(
            servers: [server("a"), server("b")], activeServerID: "a", enabled: true,
            excluded: [], lastActivated: [:], credential: anyCredential)
        #expect(plan.map(\.server.id) == ["b"])
        #expect(plan.first?.credential == SessionCredential(userID: "u-b", token: "t-b"))
    }

    @Test func mostRecentlyActivatedFirstThenKnownOrder() {
        let plan = ParticipantPlanner.plan(
            servers: [server("a"), server("b"), server("c"), server("d")], activeServerID: "a", enabled: true,
            excluded: [], lastActivated: ["d": Date(timeIntervalSince1970: 50), "c": Date(timeIntervalSince1970: 10)],
            credential: anyCredential)
        #expect(plan.map(\.server.id) == ["d", "c", "b"])
    }

    @Test func capsAtFourSecondaries() {
        let servers = (0..<8).map { server("s\($0)") }
        let plan = ParticipantPlanner.plan(
            servers: servers, activeServerID: "s0", enabled: true,
            excluded: [], lastActivated: [:], credential: anyCredential)
        #expect(plan.map(\.server.id) == ["s1", "s2", "s3", "s4"])
    }

    @Test func excludedAndCredentiallessServersDropOutBeforeTheCap() {
        let servers = (0..<7).map { server("s\($0)") }
        let plan = ParticipantPlanner.plan(
            servers: servers, activeServerID: "s0", enabled: true,
            excluded: ["s1"], lastActivated: [:],
            credential: { $0 == "s2" ? nil : SessionCredential(userID: "u", token: "t") })
        #expect(plan.map(\.server.id) == ["s3", "s4", "s5", "s6"])
    }

    @Test func preferenceIsPerProfileScope() {
        let prefs = CombinedServersPreferences(defaults: UserDefaults(suiteName: "combine-\(UUID().uuidString)")!)
        prefs.setEnabled(true, scope: "srv:a")
        prefs.setExcluded(["x", "y"], scope: "srv:a")
        #expect(prefs.isEnabled(scope: "srv:a"))
        #expect(!prefs.isEnabled(scope: "srv:b"))
        #expect(prefs.excludedServerIDs(scope: "srv:a") == ["x", "y"])
        #expect(prefs.excludedServerIDs(scope: "srv:b").isEmpty)
    }

    /// Parental preferences live in `.standard`, so this test restores what it set (same pattern as
    /// `ParentalControlsActiveTests`).
    @Test func gatedResumableProfileDoesNotTakePart() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        try container.rememberUser(RememberedUser(id: "kid", serverID: "srv-b", name: "Kid", imageTag: nil, token: "tk"))
        #expect(container.secondaryCredential(serverID: "srv-b") == SessionCredential(userID: "kid", token: "tk"))

        try container.saveGuardianPIN("1234")
        container.parentalControlsPreferences.setRole(.pinToEnter, serverID: "srv-b", userID: "kid")
        defer { container.parentalControlsPreferences.setRole(.open, serverID: "srv-b", userID: "kid") }

        #expect(container.secondaryCredential(serverID: "srv-b") == nil)
    }

    @Test func deviceTokenSlotWinsOverRememberedProfiles() throws {
        let keychain = InMemoryKeychain()
        let container = DependencyContainer(
            keychainService: keychain, defaults: UserDefaults(suiteName: "planner-\(UUID().uuidString)")!)
        try keychain.save("slot-token", for: KeychainKeys.accessToken(serverID: "srv-b"))
        try keychain.save("slot-user", for: KeychainKeys.userID(serverID: "srv-b"))
        try container.rememberUser(RememberedUser(id: "other", serverID: "srv-b", name: "O", imageTag: nil, token: "tk"))
        #expect(container.secondaryCredential(serverID: "srv-b") == SessionCredential(userID: "slot-user", token: "slot-token"))
    }
}

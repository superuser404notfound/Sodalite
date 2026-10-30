import Foundation
import Testing
@testable import Sodalite

/// The combined shelf's sessions (Sodalite#218): which servers the extension asks, and which one an
/// item's artwork, cell identity and playback belong to.
@MainActor
struct TopShelfCombinedSessionsTests {
    private let active = SharedSession(baseURL: URL(string: "http://a.lan:8096")!, userID: "u-a", accessToken: "tok-a")

    private func participants(for userID: String) -> ShelfParticipants {
        ShelfParticipants(activeUserID: userID, secondaries: [
            .init(serverID: "b", serverURL: "http://b.lan:8096", userID: "u-b", accessToken: "tok-b"),
        ])
    }

    private func item(_ id: String) throws -> TopShelfItem {
        try JSONDecoder().decode(TopShelfItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie"}"#.utf8))
    }

    @Test func secondariesJoinForTheProfileTheyWereWrittenFor() {
        let sessions = ShelfSessions(active: active, participants: participants(for: "u-a"))
        #expect(sessions.all.map(\.baseURL.host) == ["a.lan", "b.lan"])
        #expect(sessions.secondaries.first?.serverID == "b")
    }

    /// The two slots are written apart; between a profile switch's two writes they disagree.
    @Test func anotherProfilesSecondariesAreLeftOut() {
        let sessions = ShelfSessions(active: active, participants: participants(for: "u-other"))
        #expect(sessions.secondaries.isEmpty)
    }

    @Test func anItemGoesToTheServerItCameFrom() throws {
        let sessions = ShelfSessions(active: active, participants: participants(for: "u-a"))
        #expect(sessions.session(for: try item("x")).accessToken == "tok-a")
        #expect(sessions.session(for: try item("x").stamped(serverID: "b")).accessToken == "tok-b")
        // Combine switched off since the item was cached: the active server, never a crash.
        #expect(sessions.session(for: try item("x").stamped(serverID: "gone")).accessToken == "tok-a")
    }

    /// The active server's cells keep the names a single-server shelf already rendered under.
    @Test func onlyASecondarysCellCarriesItsServer() throws {
        let id = "0f9b1c2d3e4f5061728394a5b6c7d8e9"
        #expect(try item(id).shelfKey == id)
        let key = try item(id).stamped(serverID: "aa11bb22cc33dd44ee55ff6600778899").shelfKey
        #expect(key.hasPrefix(id + "-"))
        #expect(key != id)
    }

    /// Two servers holding the same id still make two cells.
    @Test func theSameIdOnTwoServersIsTwoCells() throws {
        let rows = TopShelfItem.shelfRows(resume: [try item("x"), try item("x").stamped(serverID: "b")], nextUp: [])
        #expect(rows.resume.count == 2)
    }

    @Test func theOriginSurvivesTheCache() throws {
        let stamped = try item("x").stamped(serverID: "b")
        let decoded = try JSONDecoder().decode(TopShelfItem.self, from: JSONEncoder().encode(stamped))
        #expect(decoded.sourceServerID == "b")
    }

    @Test func theRegistryMirrorsItsSecondaries() {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        let registry = ServerSessionRegistry(activeClient: live, httpClient: http)
        #expect(registry.shelfParticipants == nil)

        var fired = 0
        registry.onSessionsChanged = { fired += 1 }
        registry.apply(active: (JellyfinServer(id: "a", name: "a", internalURL: URL(string: "http://a.lan:8096"), externalURL: nil), "u-a"),
                       secondaries: [ParticipantCandidate(server: JellyfinServer(id: "b", name: "b", internalURL: URL(string: "http://b.lan:8096"), externalURL: nil),
                                                          credential: SessionCredential(userID: "u-b", token: "tok-b"))],
                       baseURL: { $0.internalURL! })
        #expect(fired == 1)
        #expect(registry.shelfParticipants == ShelfParticipants(activeUserID: "u-a", secondaries: [
            .init(serverID: "b", serverURL: "http://b.lan:8096", userID: "u-b", accessToken: "tok-b"),
        ]))

        registry.updateRoute(URL(string: "https://b.example.com")!, for: registry.session(forServerID: "b"))
        #expect(fired == 2)
        #expect(registry.shelfParticipants?.secondaries.first?.serverURL == "https://b.example.com")
    }
}

import Foundation
import Testing
@testable import Sodalite

/// Findings from the Phase 1 branch review (Sodalite#85).
@Suite(.serialized)
@MainActor
struct CombinedServersReviewFixTests {
    private func server(_ id: String, _ url: String) -> JellyfinServer {
        JellyfinServer(id: id, name: id, internalURL: URL(string: url), externalURL: nil)
    }

    /// A device token slot is not a free pass: a PIN-guarded profile stays out of a combined Home
    /// whichever way its token is stored.
    @Test func guardedTokenSlotDoesNotTakePart() throws {
        let keychain = InMemoryKeychain()
        let container = DependencyContainer(keychainService: keychain)
        try keychain.save("slot-token", for: KeychainKeys.accessToken(serverID: "srv-b"))
        try keychain.save("dad", for: KeychainKeys.userID(serverID: "srv-b"))
        #expect(container.secondaryCredential(serverID: "srv-b") != nil)

        try container.saveGuardianPIN("1234")
        container.parentalControlsPreferences.setRole(.pinToEnter, serverID: "srv-b", userID: "dad")
        defer { container.parentalControlsPreferences.setRole(.open, serverID: "srv-b", userID: "dad") }

        #expect(container.secondaryCredential(serverID: "srv-b") == nil)
    }

    @Test func aReusedSecondaryFollowsItsServersNewAddress() {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        let registry = ServerSessionRegistry(activeClient: live, httpClient: http)
        let credential = SessionCredential(userID: "u-b", token: "tok-b")
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"),
                       secondaries: [ParticipantCandidate(server: server("b", "http://old.lan:8096"), credential: credential)],
                       baseURL: { $0.url })
        registry.apply(active: (server("a", "http://a.lan:8096"), "u-a"),
                       secondaries: [ParticipantCandidate(server: server("b", "http://new.lan:8096"), credential: credential)],
                       baseURL: { $0.url })
        let session = registry.session(forServerID: "b")
        #expect(session.server?.internalURL == URL(string: "http://new.lan:8096"))
        #expect(session.client.baseURL == URL(string: "http://new.lan:8096"))
    }

    @Test func castPortraitsComeFromTheItemsServer() throws {
        let service = JellyfinImageService(endpoint: { serverID in
            serverID == "b" ? (URL(string: "http://b.lan:8096")!, "tok-b") : (URL(string: "http://a.lan:8096")!, "tok-a")
        })
        let person = try JSONDecoder().decode(
            PersonInfo.self, from: Data(#"{"Id":"p1","Name":"N","PrimaryImageTag":"t"}"#.utf8))
        let cast = jellyfinCastMembers(from: [person], imageService: service, imageWidth: 200, serverID: "b")
        #expect(cast.first?.imageURL?.host == "b.lan")
    }

    /// Two servers behind one reverse proxy, told apart by path only.
    @Test func imageAuthTellsPathPrefixesApart() {
        let auth = ImageAuth(bases: [
            (URL(string: "https://media.example.com/jfA")!, "tok-a"),
            (URL(string: "https://media.example.com/jfB")!, "tok-b"),
        ])
        #expect(auth.token(for: URL(string: "https://media.example.com/jfA/Items/1/Images/Primary")!) == "tok-a")
        #expect(auth.token(for: URL(string: "https://media.example.com/jfB/Items/1/Images/Primary")!) == "tok-b")
        #expect(auth.token(for: URL(string: "https://media.example.com/other/x")!) == nil)
    }

    @Test func imageAuthPrefersTheLongestMatchingBase() {
        let auth = ImageAuth(bases: [
            (URL(string: "https://media.example.com")!, "tok-root"),
            (URL(string: "https://media.example.com/jfB/")!, "tok-b"),
        ])
        #expect(auth.token(for: URL(string: "https://media.example.com/jfB/Items/1")!) == "tok-b")
        #expect(auth.token(for: URL(string: "https://media.example.com/Items/1")!) == "tok-root")
        #expect(auth.token(for: URL(string: "https://media.example.com/jfBx/Items/1")!) == "tok-root")
    }
}

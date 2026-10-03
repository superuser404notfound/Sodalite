import Foundation
import Testing
@testable import Sodalite

@MainActor
struct ImageAuthTests {
    private func registry() -> ServerSessionRegistry {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        live.baseURL = URL(string: "http://nas:8096")
        live.accessToken = "tok-a"
        let registry = ServerSessionRegistry(activeClient: live, httpClient: http)
        registry.apply(
            active: (JellyfinServer(id: "a", name: "A", internalURL: URL(string: "http://nas:8096"), externalURL: nil), "u-a"),
            secondaries: [ParticipantCandidate(
                server: JellyfinServer(id: "b", name: "B", internalURL: URL(string: "http://nas:8097"), externalURL: nil),
                credential: SessionCredential(userID: "u-b", token: "tok-b"))],
            baseURL: { $0.url })
        return registry
    }

    @Test func sameHostDifferentPortGetsItsOwnToken() {
        let auth = ImageAuth.snapshot(registry())
        #expect(auth.token(for: URL(string: "http://nas:8096/Items/1/Images/Primary")!) == "tok-a")
        #expect(auth.token(for: URL(string: "http://nas:8097/Items/1/Images/Primary")!) == "tok-b")
    }

    @Test func foreignHostsGetNothing() {
        let auth = ImageAuth.snapshot(registry())
        #expect(auth.token(for: URL(string: "https://image.tmdb.org/t/p/w500/x.jpg")!) == nil)
        #expect(auth.token(for: URL(string: "http://nas:9000/x")!) == nil)
    }

    @Test func defaultPortsMatchImplicitly() {
        let auth = ImageAuth(bases: [(URL(string: "https://jf.example")!, "tok")])
        #expect(auth.token(for: URL(string: "https://jf.example/Items/1")!) == "tok")
        #expect(auth.token(for: URL(string: "https://jf.example:443/Items/1")!) == "tok")
        #expect(auth.token(for: URL(string: "http://jf.example/Items/1")!) == nil)
    }
}

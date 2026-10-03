import Foundation
import SwiftUI
import Testing
@testable import Sodalite

@MainActor
struct ServerSessionEnvironmentTests {
    @Test func environmentDefaultsToNil() {
        #expect(EnvironmentValues().serverSession == nil)
    }

    @Test func onlyTheActiveSessionAllowsDeleteAndDownload() {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        live.baseURL = URL(string: "http://a.lan:8096")
        let registry = ServerSessionRegistry(activeClient: live, httpClient: http)
        registry.apply(
            active: (JellyfinServer(id: "a", name: "A", internalURL: URL(string: "http://a.lan:8096"), externalURL: nil), "u-a"),
            secondaries: [ParticipantCandidate(
                server: JellyfinServer(id: "b", name: "B", internalURL: URL(string: "http://b.lan:8096"), externalURL: nil),
                credential: SessionCredential(userID: "u-b", token: "t"))],
            baseURL: { $0.url })
        #expect(registry.active.allowsDeleteAndDownload)
        #expect(!registry.session(forServerID: "b").allowsDeleteAndDownload)
    }
}

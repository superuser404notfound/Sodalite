import Foundation
import Testing
@testable import Sodalite

/// A combined-Home server applies the policy of the account Sodalite uses there, not the server
/// default (Sodalite#202 round 3).
@MainActor
struct SecondaryServerPolicyTests {
    private typealias Stub = JellyfinPasswordAdoptionTests.StubHTTPClient

    private func me(videoTranscoding: Bool) -> Data {
        Data(#"{"Id": "u-b", "Name": "B", "ServerId": "b", "Policy": {"IsAdministrator": false, "EnableContentDeletion": false, "EnableVideoPlaybackTranscoding": \#(videoTranscoding)}}"#.utf8)
    }

    private func secondary(over http: Stub) -> ServerSession {
        ServerSession.secondary(
            ParticipantCandidate(
                server: JellyfinServer(id: "b", name: "b", internalURL: URL(string: "http://b.lan:8096"), externalURL: nil),
                credential: SessionCredential(userID: "u-b", token: "tok-b")),
            baseURL: URL(string: "http://b.lan:8096")!,
            httpClient: http)
    }

    @Test func theSecondaryAccountsPolicyGatesTranscoding() async {
        let http = Stub()
        http.responses["/Users/Me"] = me(videoTranscoding: false)
        let session = secondary(over: http)
        let state = AppState()

        #expect(state.canTranscodeVideo(on: session), "unloaded keeps the server default")
        await session.loadUserIfNeeded()
        #expect(state.canTranscodeVideo(on: session) == false)
    }

    @Test func aGrantedPolicyKeepsTheRungs() async {
        let http = Stub()
        http.responses["/Users/Me"] = me(videoTranscoding: true)
        let session = secondary(over: http)
        await session.loadUserIfNeeded()
        #expect(AppState().canTranscodeVideo(on: session))
    }

    /// A server that was away is asked again; one that answered is not asked twice.
    @Test func aFailedLoadIsRetriedAndASuccessIsKept() async {
        let http = Stub()
        let session = secondary(over: http)
        await session.loadUserIfNeeded()
        #expect(session.user == nil)

        http.responses["/Users/Me"] = me(videoTranscoding: false)
        await session.loadUserIfNeeded()
        await session.loadUserIfNeeded()
        #expect(session.user?.canTranscodeVideo == false)
        #expect(http.requestedPaths == ["/Users/Me", "/Users/Me"])
    }
}

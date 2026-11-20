import Foundation
import Testing
@testable import Sodalite

@Suite(.serialized)
@MainActor
struct CombinedLiveTVReviewFixTests {
    typealias FakeLive = CombinedLiveTVTests.FakeLive

    private func source(_ id: String, _ live: FakeLive, active: Bool) -> LiveTVSource {
        let client = JellyfinClient()
        return LiveTVSource(serverID: id, serverName: id.uppercased(), userID: "u-\(id)", liveTvService: live,
                            playbackService: JellyfinPlaybackService(client: client),
                            itemService: JellyfinItemService(client: client), isActive: active)
    }

    private func user(manage: Bool, delete: Bool = false) throws -> JellyfinUser {
        try JSONDecoder().decode(JellyfinUser.self, from: Data(
            #"{"Id":"u","Name":"n","ServerId":"s","Policy":{"IsAdministrator":false,"EnableLiveTvManagement":\#(manage),"EnableContentDeletion":\#(delete)}}"#.utf8))
    }

    // Finding 4: one slow answer during a re-probe must not take the server away.
    @Test func aTimedOutSecondaryThatHadLiveTVStays() async {
        let a = FakeLive(); a.channelCount = 1
        let b = FakeLive(); b.channelCount = 1; b.delay = .seconds(5)
        let ids = await LiveTVProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)],
            secondaryDeadline: .milliseconds(200), previouslyCapable: ["b"])
        #expect(ids == ["a", "b"])
    }

    @Test func aFailingSecondaryDropsEvenIfItHadLiveTV() async {
        let a = FakeLive(); a.channelCount = 1
        let b = FakeLive(); b.fail = true
        let ids = await LiveTVProbe.capableServerIDs(
            [source("a", a, active: true), source("b", b, active: false)],
            secondaryDeadline: .seconds(1), previouslyCapable: ["b"])
        #expect(ids == ["a"])
    }

    // Finding 5: a remembered server that left the participants before the probe caught up.
    @Test func aRememberedServerThatLeftFallsToTheNextCapableNotTheActive() {
        #expect(LiveTVServerChoice.resolve(
            capable: ["b", "c"], available: ["a", "c"], remembered: "b", pinned: nil) == "c")
    }

    // Finding 4: the server under a running player does not change.
    @Test func thePinnedServerHoldsWhileThePlayerRuns() {
        #expect(LiveTVServerChoice.resolve(
            capable: ["a"], available: ["a", "b"], remembered: nil, pinned: "b") == "b")
    }

    @Test func nothingCapableAndAvailableResolvesToNil() {
        #expect(LiveTVServerChoice.resolve(capable: ["b"], available: ["a"], remembered: "b", pinned: nil) == nil)
    }

    // Finding 6: a late route resolution on a secondary is a reason to probe again.
    @Test func aChangedSecondaryRouteBumpsTheRoutesRevision() {
        let http = HTTPClient()
        let live = JellyfinClient(httpClient: http)
        live.baseURL = URL(string: "http://a.lan:8096"); live.accessToken = "tok-a"
        let registry = ServerSessionRegistry(activeClient: live, httpClient: http)
        registry.apply(
            active: (JellyfinServer(id: "a", name: "a", internalURL: URL(string: "http://a.lan:8096"), externalURL: nil), "u-a"),
            secondaries: [ParticipantCandidate(
                server: JellyfinServer(id: "b", name: "b", internalURL: URL(string: "http://b.lan:8096"), externalURL: nil),
                credential: SessionCredential(userID: "u-b", token: "tok-b"))],
            baseURL: { $0.url })
        let session = registry.session(forServerID: "b")
        let before = registry.routesRevision
        registry.updateRoute(URL(string: "http://b.lan:8096")!, for: session)
        #expect(registry.routesRevision == before)
        registry.updateRoute(URL(string: "https://b.example.com")!, for: session)
        #expect(registry.routesRevision == before &+ 1)
        #expect(session.client.baseURL == URL(string: "https://b.example.com"))
    }

    // Finding 7: rights on a secondary are that server's user's, unknown means no.
    @Test func secondaryRightsComeFromTheSecondaryUser() throws {
        let admin = try user(manage: true, delete: true)
        let plain = try user(manage: false)
        #expect(LiveTVPolicy(isActiveSource: false, activeUser: admin, sessionUser: plain).canManageLiveTv == false)
        #expect(LiveTVPolicy(isActiveSource: false, activeUser: plain, sessionUser: admin).canManageLiveTv)
        #expect(LiveTVPolicy(isActiveSource: false, activeUser: admin, sessionUser: nil).canManageLiveTv == false)
        #expect(LiveTVPolicy(isActiveSource: false, activeUser: admin, sessionUser: nil).canDeleteContent == false)
        #expect(LiveTVPolicy(isActiveSource: true, activeUser: admin, sessionUser: nil).canManageLiveTv)
    }
}

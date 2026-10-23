import Testing
import Foundation
@testable import Sodalite

/// Sodalite#147: a live session that ends because the Apple TV went away rather than because the
/// viewer pressed Back is never closed server-side. Every release the app has hangs off a teardown
/// that only runs while it is on screen, and the tuner handle lives in a field that dies with the
/// process, so the tuner and its growing `.ts` are held until the server restarts (#70: Jellyfin has
/// no reaper for an open live stream).
///
/// The ledger is the durable half of the bookkeeping `LiveTunerGate` does inside one process.
@Suite("The tuner ledger and its sweep (Sodalite#147)")
struct LiveTunerLedgerTests {

    private func scratchDefaults() -> UserDefaults {
        let suite = "test.liveTunerLedger.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func record(
        user: String = "user-1",
        item: String = "channel-1",
        key: String = "stream-1",
        opened: Date = Date()
    ) -> OpenLiveStreamRecord {
        OpenLiveStreamRecord(
            userID: user, itemID: item, liveStreamID: key,
            mediaSourceID: "source-1", playSessionID: "play-1", openedAt: opened)
    }

    /// The whole point: what one run wrote down, the next run can still read. Written by one ledger
    /// and read by a second one over the same store, which is the process boundary in miniature.
    @Test func aHandleSurvivesTheProcessThatOpenedIt() {
        let defaults = scratchDefaults()
        LiveTunerLedger(defaults: defaults).remember(record())

        let nextLaunch = LiveTunerLedger(defaults: defaults)
        #expect(nextLaunch.orphans(userID: "user-1").map(\.liveStreamID) == ["stream-1"])
    }

    /// A handle this process is still playing is the same shape as one a kill left behind, and
    /// closing it would take the picture off the screen.
    @Test func theChannelPlayingRightNowIsNotAnOrphan() {
        let ledger = LiveTunerLedger(defaults: scratchDefaults())
        ledger.remember(record())
        #expect(ledger.orphans(userID: "user-1").isEmpty)
    }

    /// A user id belongs to exactly one server, so it names the server too: a leftover from a session
    /// this launch is not signed in to must not have its handle fired at whichever server is active.
    @Test func aLeftoverFromAnotherSessionIsLeftAlone() {
        let defaults = scratchDefaults()
        LiveTunerLedger(defaults: defaults).remember(record(user: "other-user"))

        let nextLaunch = LiveTunerLedger(defaults: defaults)
        #expect(nextLaunch.orphans(userID: "user-1").isEmpty)
        #expect(nextLaunch.orphans(userID: "other-user").count == 1)
    }

    @Test func aClosedHandleIsForgotten() {
        let defaults = scratchDefaults()
        let ledger = LiveTunerLedger(defaults: defaults)
        ledger.remember(record())
        ledger.forget(liveStreamID: "stream-1")
        #expect(LiveTunerLedger(defaults: defaults).orphans(userID: "user-1").isEmpty)
    }

    /// Re-tuning the same channel hands back the same id (it names the channel), so the ledger has to
    /// hold one entry per handle rather than one per tune.
    @Test func reopeningTheSameChannelDoesNotStackUp() {
        let defaults = scratchDefaults()
        let ledger = LiveTunerLedger(defaults: defaults)
        ledger.remember(record(opened: Date(timeIntervalSince1970: 100)))
        ledger.remember(record(opened: Date(timeIntervalSince1970: 200)))
        #expect(LiveTunerLedger(defaults: defaults).orphans(userID: "user-1").count == 1)
    }

    /// A server that answers no close at all must not be able to grow the list without end.
    @Test func theLedgerIsBounded() {
        let defaults = scratchDefaults()
        let ledger = LiveTunerLedger(defaults: defaults)
        for index in 0..<(LiveTunerLedger.capacity + 4) {
            ledger.remember(record(item: "channel-\(index)", key: "stream-\(index)"))
        }
        let kept = LiveTunerLedger(defaults: defaults).orphans(userID: "user-1")
        #expect(kept.count == LiveTunerLedger.capacity)
        // The oldest go first: the newest leftover is the one a tuner is most likely still ingesting for.
        #expect(!kept.contains { $0.liveStreamID == "stream-0" })
        #expect(kept.contains { $0.liveStreamID == "stream-\(LiveTunerLedger.capacity + 3)" })
    }

    /// A close that never reached the server is one no launch should stop looking for, and it is the
    /// only case where a handle belongs back in the ledger after a teardown has taken it out.
    @Test func aCloseThatNeverArrivedPutsItsHandleBack() {
        let defaults = scratchDefaults()
        let ledger = LiveTunerLedger(defaults: defaults)
        ledger.remember(record())

        let taken = ledger.take(liveStreamID: "stream-1")
        #expect(taken?.liveStreamID == "stream-1")
        #expect(LiveTunerLedger(defaults: defaults).orphans(userID: "user-1").isEmpty)

        ledger.restore(taken!)
        // Visible to this process too: nothing is playing it any more.
        #expect(ledger.orphans(userID: "user-1").count == 1)
    }

    /// The id names the CHANNEL, so a re-negotiation closes one handle and opens the next under the
    /// same string. A late failure from the first close must not put a dead record on top of the live
    /// one, and must not make the channel playing right now look like an orphan.
    @Test func aLateFailureCannotOverwriteTheTuneThatFollowedIt() {
        let ledger = LiveTunerLedger(defaults: scratchDefaults())
        ledger.remember(record(opened: Date(timeIntervalSince1970: 100)))
        let taken = ledger.take(liveStreamID: "stream-1")!
        ledger.remember(record(opened: Date(timeIntervalSince1970: 200)))

        ledger.restore(taken)
        #expect(ledger.orphans(userID: "user-1").isEmpty)
    }

    // MARK: - Who may be closed

    /// `LiveStreamId` names the CHANNEL, not the stream, so a stale one aimed blind lands on whatever
    /// is registered for that channel now (#70).
    @Test func aChannelAnotherClientIsWatchingIsNotClosed() {
        let sessions = [
            JellyfinSessionInfo(deviceID: "someone-else", nowPlayingItemID: "channel-1")
        ]
        #expect(!LiveStreamSweep.mayClose(record(), sessions: sessions, ourDeviceID: "us"))
    }

    /// Our own session still listed as playing is the reported symptom, not a reason to stand down:
    /// that listing IS the stop report that never arrived.
    @Test func ourOwnStaleSessionIsNoObstacle() {
        let sessions = [JellyfinSessionInfo(deviceID: "us", nowPlayingItemID: "channel-1")]
        #expect(LiveStreamSweep.mayClose(record(), sessions: sessions, ourDeviceID: "us"))
    }

    @Test func anotherClientOnAnotherChannelIsNoObstacle() {
        let sessions = [
            JellyfinSessionInfo(deviceID: "someone-else", nowPlayingItemID: "channel-9"),
            JellyfinSessionInfo(deviceID: "someone-else", nowPlayingItemID: nil)
        ]
        #expect(LiveStreamSweep.mayClose(record(), sessions: sessions, ourDeviceID: "us"))
    }

    /// A server that would not answer the question leaves an empty list, and the sweep goes ahead:
    /// a leak costs every client on that tuner host until the server restarts, while the hazard it
    /// trades against needs a stranger to be on that exact channel at this exact moment.
    @Test func noAnswerIsNotAVeto() {
        #expect(LiveStreamSweep.mayClose(record(), sessions: [], ourDeviceID: "us"))
    }

    /// A session with no device id could be anyone, and the question is asked to be sure.
    @Test func anUnnamedDeviceCountsAsSomebodyElse() {
        let sessions = [JellyfinSessionInfo(deviceID: nil, nowPlayingItemID: "channel-1")]
        #expect(!LiveStreamSweep.mayClose(record(), sessions: sessions, ourDeviceID: "us"))
    }

    // MARK: - The sweep

    @Test func theSweepClosesWhatAnEarlierRunLeftOpen() async {
        let defaults = scratchDefaults()
        LiveTunerLedger(defaults: defaults).remember(record())
        let service = SweepMockService()

        await LiveTunerLedger(defaults: defaults).sweep(userID: "user-1", using: service)

        #expect(service.closedLiveStreams == ["stream-1"])
        #expect(service.stoppedReports.map(\.liveStreamId) == ["stream-1"])
        #expect(service.killedEncodings == ["play-1"])
        // Gone from the ledger, so the launch after this one has nothing to repeat.
        #expect(LiveTunerLedger(defaults: defaults).orphans(userID: "user-1").isEmpty)
    }

    /// The transcode kill is addressed to (this device, that play session) and can reach nothing but
    /// our own orphan, so it is sent whichever way the channel-scoped close goes.
    @Test func aChannelInUseKeepsItsRecordAndStillGetsItsEncodingKilled() async {
        let defaults = scratchDefaults()
        LiveTunerLedger(defaults: defaults).remember(record())
        let service = SweepMockService()
        service.sessions = [
            JellyfinSessionInfo(deviceID: "someone-else", nowPlayingItemID: "channel-1")
        ]

        await LiveTunerLedger(defaults: defaults).sweep(userID: "user-1", using: service)

        #expect(service.closedLiveStreams.isEmpty)
        #expect(service.stoppedReports.isEmpty)
        #expect(service.killedEncodings == ["play-1"])
        // Kept: the next launch may find the channel free.
        #expect(LiveTunerLedger(defaults: defaults).orphans(userID: "user-1").count == 1)
    }

    @Test func aRunWithNothingStrandedAsksTheServerNothing() async {
        let service = SweepMockService()
        await LiveTunerLedger(defaults: scratchDefaults()).sweep(userID: "user-1", using: service)
        #expect(!service.askedForSessions)
        #expect(service.closedLiveStreams.isEmpty)
    }

    // MARK: - Decoding

    /// Only two fields out of a session object, so the sweep's small question never drags the whole
    /// library model and its date formats behind it.
    @Test func sessionsDecodeDownToTheTwoFieldsTheSweepNeeds() throws {
        let json = """
        [
          {"Id":"s1","DeviceId":"atv-1","UserName":"vincent",
           "NowPlayingItem":{"Id":"channel-1","Name":"BBC One","Type":"TvChannel"}},
          {"Id":"s2","DeviceId":"phone-1","LastActivityDate":"2026-09-14T12:00:00.0000000Z"}
        ]
        """
        let sessions = try JSONDecoder().decode([JellyfinSessionInfo].self, from: Data(json.utf8))
        #expect(sessions.count == 2)
        #expect(sessions[0].deviceID == "atv-1")
        #expect(sessions[0].nowPlayingItemID == "channel-1")
        #expect(sessions[1].deviceID == "phone-1")
        #expect(sessions[1].nowPlayingItemID == nil)
    }

    @Test func theSessionsRouteIsWhereJellyfinPutsIt() {
        #expect(JellyfinEndpoint.sessions.path == "/Sessions")
        #expect(JellyfinEndpoint.sessions.method == .get)
        #expect(JellyfinEndpoint.sessions.requiresAuth)
    }
}

/// Records what the sweep sent, and answers whatever the test wants the server to say.
private final class SweepMockService: JellyfinPlaybackServiceProtocol, @unchecked Sendable {
    var sessions: [JellyfinSessionInfo] = []
    var askedForSessions = false
    var closedLiveStreams: [String] = []
    var killedEncodings: [String] = []
    var stoppedReports: [PlaybackStopReport] = []

    var baseURL: URL? { URL(string: "http://server") }
    var deviceID: String { "us" }

    func getSessions() async throws -> [JellyfinSessionInfo] {
        askedForSessions = true
        return sessions
    }
    func closeLiveStream(liveStreamID: String) async throws { closedLiveStreams.append(liveStreamID) }
    func stopActiveEncodings(playSessionID: String) async throws { killedEncodings.append(playSessionID) }
    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws { stoppedReports.append(report) }

    private struct NotUsed: Error {}
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse { throw NotUsed() }
    func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]?, maxStreamingBitrate: Int, enableDirectPlay: Bool, autoOpenLiveStream: Bool) async throws -> PlaybackInfoResponse { throw NotUsed() }
    func reportPlaybackStart(_ report: PlaybackStartReport) async throws {}
    func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws {}
    func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] { [] }
    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] { [] }
    func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments { throw NotUsed() }
    func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? { nil }
    func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? { nil }
    func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? { nil }
    func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL? { nil }
    func buildTrickplayTileURL(itemID: String, width: Int, tileIndex: Int) -> URL? { nil }
    func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo] { [] }
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {}
    func deleteSubtitle(itemID: String, index: Int) async throws {}
    func buildTranscodeURL(relativePath: String) -> URL? { nil }
    func buildLiveStreamFileURL(sourcePath: String) -> URL? { nil }
}

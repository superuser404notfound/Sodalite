import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// One session-close path (audit PCORE-R201, PHOST-R201) and the findings that fell out of it:
/// PCORE-201 / 202, PHOST-201 / 202 / 204 / 205 / 206.
@MainActor
struct SessionCloseTests {

    private func episode() throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","SeriesId":"show-1","RunTimeTicks":36000000000}"#.utf8)
        )
    }

    private func makeViewModel(_ service: RecordingPlaybackService, item: JellyfinItem? = nil) throws -> PlayerViewModel {
        let suite = "test.sessionClose.\(UUID().uuidString)"
        return PlayerViewModel(
            item: try item ?? episode(),
            startFromBeginning: false,
            playbackService: service,
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: suite)!)
        )
    }

    private let channel = JellyfinChannel(id: "ch-1", name: "One", channelNumber: "1",
                                          imageTags: nil, currentProgram: nil, userData: nil)

    private func makeLiveViewModel(_ service: RecordingPlaybackService,
                                   liveTv: JellyfinLiveTvServiceProtocol? = nil) -> PlayerViewModel {
        PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: service,
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.sessionClose.\(UUID())")!),
            isLiveSession: true,
            liveChannel: channel,
            liveTvService: liveTv)
    }

    private func settle(_ service: RecordingPlaybackService, kills: Int) async {
        await waitUntil { service.killedEncodings.count >= kills }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - PHOST-201

    @Test func aHeldSessionThatNeverPlayedSendsNoStop() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.progressReportsHeldForSuspension = true

        vm.stopPlayback()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.isEmpty)
    }

    @Test func aHeldSessionThatPlayedOrEndedInTheBackgroundSendsItsStop() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.progressReportsHeldForSuspension = true
        vm.playedWhileReportsHeld = true

        vm.stopPlayback()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.count == 1)
    }

    /// R-SESSION-CLOSE-1: a Play press on a torn-down session flips the engine state with no pipeline
    /// behind it. The sink's latch ignores it, and the return check's veto beats anything else.
    @Test func aStateWithoutAPipelineDoesNotLatch() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.progressReportsHeldForSuspension = true
        vm.noteEngineStateWhileHeld(.playing)
        vm.noteEngineStateWhileHeld(.ended)
        #expect(vm.playedWhileReportsHeld == false)
    }

    @Test func theLatchNeedsAPipelineAndNoPendingReload() {
        #expect(SuspendedSessionReturn.latchesPlayed(held: true, backendRunning: true, awaitingReload: false))
        #expect(!SuspendedSessionReturn.latchesPlayed(held: true, backendRunning: false, awaitingReload: false))
        #expect(!SuspendedSessionReturn.latchesPlayed(held: true, backendRunning: true, awaitingReload: true))
        #expect(!SuspendedSessionReturn.latchesPlayed(held: false, backendRunning: true, awaitingReload: false))
    }

    @Test func aVetoedCloseSendsNoStopWhateverTheLatchSays() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.progressReportsHeldForSuspension = true
        vm.playedWhileReportsHeld = true
        vm.isPlaying = true
        vm.stopReportVetoed = true

        vm.stopPlayback()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.isEmpty)
    }

    /// R-SESSION-CLOSE-2: a film already playing in PiP emits no new state after the hold goes up.
    @Test func aSessionInPictureInPictureWhenHeldKeepsItsStop() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.holdReportsForSuspension(pictureInPictureActive: true, backgroundAudioPlaying: false)

        vm.stopPlayback()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.count == 1)
    }

    @Test func changingTheHoldClearsThePlayedLatch() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.progressReportsHeldForSuspension = true
        vm.playedWhileReportsHeld = true
        vm.progressReportsHeldForSuspension = false
        #expect(vm.playedWhileReportsHeld == false)
    }

    // MARK: - PCORE-201 / 202

    @Test func theCloseSendsTraktAStopAndTellsHomeTheSeries() async throws {
        let service = RecordingPlaybackService()
        var item = try episode()
        item.serverID = "server-2"
        let vm = try makeViewModel(service, item: item)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.traktScrobbleState = (item.id, true)

        var seen: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(
            forName: .playbackProgressDidChange, object: nil, queue: .main) { note in
            seen = note.userInfo
        }
        defer { NotificationCenter.default.removeObserver(token) }

        vm.makeServerSessionClose(positionTicks: 1_000)()
        await settle(service, kills: 1)

        #expect(vm.traktScrobbleState == nil)
        #expect(seen?[PlaybackProgressKey.itemID] as? String == "ep-1")
        #expect(seen?[PlaybackProgressKey.seriesID] as? String == "show-1")
        #expect(seen?[PlaybackProgressKey.serverID] as? String == "server-2")
    }

    @Test func anItemSwitchClosesThroughTheSharedPath() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.traktScrobbleState = ("ep-1", true)
        vm.nextEpisode = try JSONDecoder().decode(
            JellyfinItem.self, from: Data(#"{"Id":"ep-2","Name":"Next","Type":"Episode"}"#.utf8))

        await vm.playNextEpisode()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.first?.itemId == "ep-1")
        #expect(service.killedEncodings.first == "ps-1")
        #expect(vm.traktScrobbleState?.itemID != "ep-1")
    }

    // MARK: - PHOST-202

    /// R-SESSION-CLOSE-4: Try Again does not wait on the stop report, and the reopen still comes
    /// after the close because LiveTunerGate holds it back.
    @Test func tryAgainOnALiveOutageClosesTheOldTunerBeforeTheReopen() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.stopReportGate = gate
        let vm = makeLiveViewModel(service)
        vm.liveTunerCloseSettle = 5
        vm.hasReportedStart = true
        vm.playSessionID = "ps-live"
        vm.activeLiveStreamID = "tuner-1"
        vm.canRetryAfterOutage = true

        vm.retryAfterOutage()
        #expect(vm.activeLiveStreamID == nil)
        await gate.arrival(1)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!service.events.contains("open:ch-1"))

        gate.open()
        await waitUntil { service.events.contains("open:ch-1") }

        let events = service.events
        let close = events.firstIndex(of: "close:tuner-1")
        let open = events.firstIndex(of: "open:ch-1")
        #expect(events.first == "stop:tuner-1")
        #expect(close != nil && open != nil && close! < open!)
        #expect(service.killedEncodings.contains("ps-live"))
        vm.stopPlayback()
    }

    // MARK: - PHOST-204

    @Test func backCancelsTheLiveRetuneZapAndReplayTasks() throws {
        let vm = makeLiveViewModel(RecordingPlaybackService())
        let retune = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        let zap = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        let replay = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        vm.liveRetuneTask = retune
        vm.zapCommitTask = zap
        vm.liveReplayRetryTask = replay

        vm.stopPlayback()

        #expect(retune.isCancelled)
        #expect(zap.isCancelled)
        #expect(replay.isCancelled)
        #expect(vm.liveRetuneTask == nil)
        #expect(vm.zapCommitTask == nil)
        #expect(vm.liveReplayRetryTask == nil)
    }

    // MARK: - PHOST-205

    /// A newer session opened while the close was waiting on the stop report: its start flag and its
    /// tuner handle stay, and only the dead handle is closed.
    @Test func aSlowCloseLeavesTheNewerSessionAlone() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.stopReportGate = gate
        let vm = makeLiveViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-old"
        vm.activeLiveStreamID = "tuner-old"

        let close = Task { await vm.closeLiveSessionServerSide() }
        await gate.arrival(1)
        vm.playSessionID = "ps-new"
        vm.activeLiveStreamID = "tuner-new"
        vm.hasReportedStart = true
        gate.open()
        await close.value
        await waitUntil { service.closedLiveStreams.count >= 1 }

        #expect(vm.activeLiveStreamID == "tuner-new")
        #expect(vm.hasReportedStart)
        #expect(service.closedLiveStreams == ["tuner-old"])
    }

    /// R-SESSION-CLOSE-3: a second close while the first waits finds nothing to take, so the channel
    /// id is closed once.
    @Test func overlappingClosesReleaseTheTunerOnce() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.stopReportGate = gate
        let vm = makeLiveViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.activeLiveStreamID = "tuner-1"

        let first = Task { await vm.closeLiveSessionServerSide() }
        await gate.arrival(1)
        await vm.closeLiveSessionServerSide()
        gate.open()
        await first.value
        try? await Task.sleep(for: .milliseconds(150))

        #expect(service.closedLiveStreams == ["tuner-1"])
        #expect(service.stoppedReports.count == 1)
    }

    // MARK: - PHOST-206

    @Test func aProgrammeAnswerForTheOldChannelDoesNotOverwriteTheNewOne() async throws {
        let gate = TestGate()
        let liveTv = GatedProgramsService(gate: gate, program: try Self.program(on: "ch-1"))
        let vm = makeLiveViewModel(RecordingPlaybackService(), liveTv: liveTv)

        let adopt = Task { await vm.adoptCurrentLiveProgram(channel: channel, service: liveTv) }
        await gate.arrival(1)
        let other = JellyfinChannel(id: "ch-2", name: "Two", channelNumber: "2",
                                    imageTags: nil, currentProgram: nil, userData: nil)
        vm.resetLiveSessionState(switchingTo: other)
        gate.open()
        _ = await adopt.value

        #expect(vm.item.id == "ch-2")
        #expect(vm.liveChannel?.id == "ch-2")
    }

    private static func program(on channelID: String) throws -> JellyfinProgram {
        let now = Date()
        return JellyfinProgram(
            id: "p-\(channelID)", channelId: channelID, channelName: "x", name: "Old Show", overview: nil,
            startDate: now.addingTimeInterval(-600), endDate: now.addingTimeInterval(600),
            genres: nil, imageTags: nil, isLive: nil, isNews: nil, isMovie: nil,
            isSeries: nil, isKids: nil, isSports: nil, seriesName: nil,
            parentIndexNumber: nil, indexNumber: nil, episodeTitle: nil,
            timerId: nil, seriesTimerId: nil)
    }
}

private final class GatedProgramsService: JellyfinLiveTvServiceProtocol, @unchecked Sendable {
    let gate: TestGate
    let program: JellyfinProgram
    init(gate: TestGate, program: JellyfinProgram) { self.gate = gate; self.program = program }

    func getPrograms(channelIDs: [String], userID: String, start: Date, end: Date) async throws -> [JellyfinProgram] {
        await gate.pass()
        return [program]
    }
    func getRecommendedPrograms(userID: String, category: LiveProgramCategory, limit: Int) async throws -> [JellyfinProgram] { [] }
    func getChannels(userID: String, startIndex: Int, limit: Int,
                     filter: GuideFilter) async throws -> LiveTvChannelsResponse {
        LiveTvChannelsResponse(items: [], totalRecordCount: 0)
    }
    func getGuideInfo() async throws -> JellyfinGuideInfo { JellyfinGuideInfo(startDate: nil, endDate: nil) }
    func getProgramIndex(userID: String, window: GuideProgramWindow, genres: String?, category: GuideFilter.Category?, cap: Int) async throws -> [JellyfinProgram] { [] }
    func setFavorite(userID: String, channelID: String, isFavorite: Bool) async throws {}
    func getRecordings(userID: String, isInProgress: Bool?) async throws -> [JellyfinItem] { [] }
    func getTimers() async throws -> [LiveTvTimer] { [] }
    func getSeriesTimers() async throws -> [LiveTvSeriesTimer] { [] }
    func createTimer(programID: String) async throws {}
    func cancelTimer(timerID: String) async throws {}
    func createSeriesTimer(programID: String) async throws {}
    func cancelSeriesTimer(timerID: String) async throws {}
}

import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Per-session player state is cleared in one place, and a task that outlives its session drops its
/// answer. Audit 2026-11-17 PCORE-203..206, R202, R204.
@MainActor
struct PlayerSessionStateTests {

    private func episode(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","RunTimeTicks":36000000000}"#.utf8))
    }

    private func makeViewModel(
        _ service: RecordingPlaybackService = RecordingPlaybackService(),
        item: JellyfinItem, preferredMediaSourceID: String? = nil
    ) -> PlayerViewModel {
        PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: service, userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.sessionstate.\(UUID())")!),
            preferredMediaSourceID: preferredMediaSourceID)
    }

    private func stream(_ index: Int, language: String = "eng", external: Bool = false) -> MediaStream {
        MediaStream(index: index, type: .subtitle, codec: "subrip", language: language,
                    displayTitle: nil, title: nil, isDefault: nil, isForced: nil,
                    isExternal: external, height: nil, width: nil, channels: nil,
                    videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                    realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
    }

    private func cue(_ id: Int) -> SubtitleCue {
        SubtitleCue(id: id, startTime: 0, endTime: 5, body: .text("line \(id)"))
    }

    private func segment(_ type: SegmentType) throws -> MediaSegment {
        try JSONDecoder().decode(MediaSegment.self, from: Data(
            #"{"Id":"s","ItemId":"x","Type":"\#(type.rawValue)","StartTicks":0,"EndTicks":10}"#.utf8))
    }

    // MARK: - The reset

    /// The list of per-session fields. A new one belongs in `resetSessionState` and here.
    @Test func anItemSwitchClearsEveryPerSessionField() throws {
        let vm = makeViewModel(item: try episode("e1"))
        vm.subtitleStreams = [stream(3)]
        vm.externalEngineTrackIDs = [3: 9]
        vm.activeSubtitleIndex = 3
        vm.activeSubtitleCodec = "srt"
        vm.subtitleCues = [cue(1)]
        vm.subtitleLoadingHintVisible = true
        vm.activeSecondarySubtitleIndex = 4
        vm.secondarySubtitleCues = [cue(2)]
        vm.activeAudioIndex = 1
        vm.activeSpeedIndex = 4
        vm.lastPlaybackTimeForNextEpisode = 500
        vm.resumeOverrideSeconds = 30
        vm.outageResumeSeconds = 40
        vm.serverConfirmedUnreachable = true
        vm.introSegment = try segment(.intro)
        vm.commercialSegments = [try segment(.commercial)]
        vm.didAutoSkipCurrentIntro = true
        vm.hasStartedPlaying = true
        vm.hasReportedStart = true
        vm.resumePositionTicks = 99
        vm.playbackTime = 120
        vm.nextEpisodeCountdown = 3
        vm.remainingSeconds = 2100
        vm.remainingSampledAt = Date()
        vm.detectedPictureArea = .fullFrame
        vm.pictureAreaScanState = .finished

        vm.resetSessionState(.itemSwitch(to: try episode("e2")))

        #expect(vm.item.id == "e2")
        #expect(vm.subtitleStreams.isEmpty)
        #expect(vm.externalEngineTrackIDs.isEmpty)
        #expect(vm.activeSubtitleIndex == nil)
        #expect(vm.activeSubtitleCodec == nil)
        #expect(vm.subtitleCues.isEmpty)
        #expect(vm.subtitleLoadingHintVisible == false)
        #expect(vm.activeSecondarySubtitleIndex == nil)
        #expect(vm.secondarySubtitleCues.isEmpty)
        #expect(vm.activeAudioIndex == nil)
        #expect(vm.activeSpeedIndex == 2)
        #expect(vm.lastPlaybackTimeForNextEpisode == 0)
        #expect(vm.resumeOverrideSeconds == nil)
        #expect(vm.outageResumeSeconds == nil)
        #expect(vm.serverConfirmedUnreachable == false)
        #expect(vm.introSegment == nil)
        #expect(vm.commercialSegments.isEmpty)
        #expect(vm.didAutoSkipCurrentIntro == false)
        #expect(vm.hasStartedPlaying == false)
        #expect(vm.hasReportedStart == false)
        #expect(vm.resumePositionTicks == 0)
        #expect(vm.playbackTime == 0)
        #expect(vm.nextEpisodeCountdown == 10)
        #expect(vm.remainingSeconds == 0)
        #expect(vm.remainingSampledAt == nil)
        #expect(vm.detectedPictureArea == nil)
        #expect(vm.pictureAreaScanState == .idle)
        #expect(vm.pictureAreaTask == nil)
    }

    /// PCORE-203: the engine drops the secondary line on every load; the view model must too.
    @Test func aReloadOfTheSameItemClearsBothSubtitlePicksAndKeepsTheItem() throws {
        let vm = makeViewModel(item: try episode("e1"))
        vm.subtitleStreams = [stream(3), stream(4)]
        vm.activeSubtitleIndex = 3
        vm.subtitleCues = [cue(1)]
        vm.activeSecondarySubtitleIndex = 4
        vm.secondarySubtitleCues = [cue(2)]
        vm.activeSpeedIndex = 4
        vm.playbackTime = 120

        vm.resetSessionState(.sameItemReload)

        #expect(vm.item.id == "e1")
        #expect(vm.subtitleStreams.count == 2)
        #expect(vm.activeSubtitleIndex == nil)
        #expect(vm.subtitleCues.isEmpty)
        #expect(vm.activeSecondarySubtitleIndex == nil)
        #expect(vm.secondarySubtitleCues.isEmpty)
        #expect(vm.activeSpeedIndex == 2)
        #expect(vm.playbackTime == 120)
    }

    @Test func secondaryCuesAreNotDrawnWithoutAPickedSecondaryTrack() throws {
        let vm = makeViewModel(item: try episode("e1"))
        vm.secondarySubtitleCues = [cue(1)]
        #expect(vm.shownSecondarySubtitleCues.isEmpty)
        vm.activeSecondarySubtitleIndex = 4
        #expect(vm.shownSecondarySubtitleCues.count == 1)
    }

    // MARK: - PCORE-204

    @Test func theLaunchVersionPickIsPinnedOnlyForTheLaunchItem() throws {
        let vm = makeViewModel(item: try episode("e1"), preferredMediaSourceID: "src-e1-2160p")
        #expect(vm.launchPinnedSourceID == "src-e1-2160p")
        vm.resetSessionState(.itemSwitch(to: try episode("e4")))
        #expect(vm.launchPinnedSourceID == nil)
    }

    // MARK: - PCORE-205

    @Test func restartingFromTheBeginningReportsZeroNotTheSessionStartPosition() throws {
        let vm = makeViewModel(item: try episode("e1"))
        vm.resumePositionTicks = 24_000_000_000
        vm.playbackTime = 3000
        vm.restartFromBeginning()
        #expect(vm.currentPositionTicks == 0)
    }

    @Test func aStopBeforeTheFirstFrameStillFallsBackToTheResumePoint() throws {
        let vm = makeViewModel(item: try episode("e1"))
        vm.resumePositionTicks = 24_000_000_000
        vm.playbackTime = 0
        #expect(vm.currentPositionTicks == 24_000_000_000)
    }

    // MARK: - PCORE-206 / R204

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aLateSegmentsAnswerNeverLandsOnTheNextEpisode() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.episodeSegmentsGate = gate
        let vm = makeViewModel(service, item: try episode("e1"))

        let fetch = Task { await vm.loadEpisodeSegments() }
        await gate.arrival(1)
        vm.resetSessionState(.itemSwitch(to: try episode("e2")))
        vm.advanceSessionGeneration()
        gate.open()
        await fetch.value

        #expect(vm.introSegment == nil)
    }

    @Test func aSegmentsAnswerInTheSameSessionIsKept() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.episodeSegmentsGate = gate
        let vm = makeViewModel(service, item: try episode("e1"))

        let fetch = Task { await vm.loadEpisodeSegments() }
        await gate.arrival(1)
        gate.open()
        await fetch.value

        #expect(vm.introSegment != nil)
    }

    @Test func stoppingBumpsTheSessionGeneration() throws {
        let vm = makeViewModel(item: try episode("e1"))
        let before = vm.sessionGeneration
        vm.stopPlayback()
        #expect(vm.sessionGeneration != before)
    }

    // MARK: - PUI-207

    @Test func anOlderSubtitleSearchThatFinishesLastDoesNotReplaceTheNewerResult() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.searchGate = gate
        let vm = makeViewModel(service, item: try episode("e1"))

        let older = Task { await vm.searchSubtitles() }
        await gate.arrival(1)
        // The viewer closes the overlay while the first search is out; its answer is stale now.
        vm.dismissSubtitleSearch()
        gate.open()
        await older.value

        #expect(vm.subtitleSearchState == .idle)
    }
}

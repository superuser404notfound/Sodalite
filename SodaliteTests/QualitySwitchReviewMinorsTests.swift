import Foundation
import Testing
@testable import Sodalite

/// The review minors of Sodalite#87 that were deferred and are now fixed.
@MainActor
struct QualitySwitchReviewMinorsTests {
    private func makeViewModel(_ service: RecordingPlaybackService) throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","RunTimeTicks":36000000000}"#.utf8))
        return PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: service, userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.qualityMinors.\(UUID().uuidString)")!))
    }

    /// #5 and #6: the reload starts a fresh engine session at 1.0x with no track picked; what the
    /// viewer had chosen must come back, whether or not track memory is on.
    @Test func aSwitchCarriesSubtitlesAndSpeedIntoTheReload() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.streamingQuality = .original
        vm.activeSubtitleIndex = 3
        vm.activeSecondarySubtitleIndex = 5
        vm.activeSpeedIndex = 4
        vm.selectStreamingQuality(.mbps4)
        #expect(vm.pendingSessionCarry == PlayerViewModel.SessionCarry(
            subtitleStreamIndex: 3, secondarySubtitleStreamIndex: 5, speedIndex: 4))
    }

    @Test func onlyAChangedSpeedIsReapplied() {
        #expect(PlayerViewModel.rateToRestore(speedIndex: 2) == nil)
        #expect(PlayerViewModel.rateToRestore(speedIndex: 4) == 1.5)
    }

    /// #11: switching from the outage error must not leave the outage state behind.
    @Test func aSwitchFromTheOutageErrorClearsTheOutage() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.streamingQuality = .original
        vm.canRetryAfterOutage = true
        vm.serverConfirmedUnreachable = true
        vm.selectStreamingQuality(.mbps4)
        #expect(!vm.canRetryAfterOutage)
        #expect(!vm.serverConfirmedUnreachable)
    }

    /// #8: a PlaybackInfo that answers after the session was torn down must not write its session.
    @Test func aLateAnswerAfterTeardownWritesNoSession() async throws {
        let service = RecordingPlaybackService()
        service.uncancellableDelayItemIDs = ["ep-1"]
        let vm = try makeViewModel(service)
        vm.beginPlayback()
        try await Task.sleep(for: .milliseconds(30))
        vm.stopPlayback()
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.playSessionID == nil)
        #expect(vm.activePlaybackSource == nil)
    }
}

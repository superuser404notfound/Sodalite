import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: a rung the file already fits under plays the original, so offering it is a choice that
/// changes nothing. The player's picker lists Original and only the rungs that actually transcode.
@MainActor
struct QualityPickerRungsTests {
    @Test func onlyTheRungsThatBiteAreOffered() {
        #expect(PlayerViewModel.pickerQualities(sourceBitrate: 17_000_000) == [.original, .mbps10, .mbps4, .mbps2])
        #expect(PlayerViewModel.pickerQualities(sourceBitrate: 3_000_000) == [.original, .mbps2])
    }

    @Test func aFileUnderEveryRungOffersOnlyTheOriginal() {
        #expect(PlayerViewModel.pickerQualities(sourceBitrate: 1_500_000) == [.original])
    }

    /// Without a bitrate nothing can be ruled out.
    @Test func anUnknownBitrateOffersEveryRung() {
        #expect(PlayerViewModel.pickerQualities(sourceBitrate: nil) == StreamingQuality.allCases)
    }

    /// A default of "Up to 20" on a 3 Mbit/s episode plays the original, so the picker marks Original.
    @Test func aRungThatDoesNotBiteShowsAsOriginal() {
        #expect(PlayerViewModel.displayedQuality(effective: .mbps20, sourceBitrate: 3_000_000) == .original)
        #expect(PlayerViewModel.displayedQuality(effective: .mbps2, sourceBitrate: 3_000_000) == .mbps2)
    }

    private func makeViewModel(_ service: RecordingPlaybackService) throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","RunTimeTicks":36000000000}"#.utf8))
        return PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: service, userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.rungs.\(UUID().uuidString)")!))
    }

    /// Switching between two rungs that both play the original restarts nothing.
    @Test func aSwitchThatChangesNothingDoesNotRestart() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .mbps20
        vm.activePlayMethod = .directPlay
        vm.activePlaybackSource = try JSONDecoder().decode(
            PlaybackMediaSource.self, from: Data(#"{"Id":"src-1","Bitrate":3000000}"#.utf8))
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"

        vm.selectStreamingQuality(.original)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(vm.streamingQuality == .original)
        #expect(service.stoppedReports.isEmpty)
        #expect(service.killedEncodings.isEmpty)
        #expect(service.requestedCaps.isEmpty)
    }
}

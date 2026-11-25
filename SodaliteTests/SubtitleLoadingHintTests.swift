import AetherEngine
import Foundation
import Testing
@testable import Sodalite

/// A picked subtitle still loading after 1.5 s shows one line saying so where the subtitle will appear.
/// Under a transcode Jellyfin extracts every subtitle from the whole file before it answers the first
/// fetch, which took 88 s for an 18 GB file, and a blank screen for that long reads as a broken track.
@MainActor
struct SubtitleLoadingHintTests {
    private func makeViewModel() throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"m1","Name":"Movie","Type":"Movie","RunTimeTicks":36000000000}"#.utf8))
        let vm = PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: RecordingPlaybackService(), userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.subtitleHint.\(UUID().uuidString)")!))
        vm.subtitleLoadingHintDelay = .milliseconds(20)
        return vm
    }

    private func waitPastDelay(_ vm: PlayerViewModel) async {
        for _ in 0..<200 where vm.subtitleLoadingHintTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aLoadPastTheDelayShowsTheHintLine() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.activeSubtitleCodec = "ass"
        vm.subtitleLoadingDidChange(true)
        #expect(vm.overlayCues.isEmpty)
        await waitPastDelay(vm)

        #expect(vm.showsSubtitleLoadingHint)
        #expect(vm.overlayCues.count == 1)
        #expect(vm.overlayCues.first?.id == SubtitleLoadingHint.cue.id)
        #expect(vm.overlaySubtitleCodec == nil)
        #expect(vm.overlayMaxCueDuration == SubtitleLoadingHint.maxCueDuration)
    }

    @Test func aLoadThatEndsInsideTheDelayNeverShowsIt() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.subtitleLoadingDidChange(true)
        vm.subtitleLoadingDidChange(false)
        await waitPastDelay(vm)
        #expect(!vm.showsSubtitleLoadingHint)
    }

    @Test func theFirstCuesReplaceIt() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.subtitleLoadingDidChange(true)
        await waitPastDelay(vm)
        let line = SubtitleCue(id: 1, startTime: 10, endTime: 12, body: .text("Hello"))
        vm.subtitleCues = [line]
        #expect(!vm.showsSubtitleLoadingHint)
        #expect(vm.overlayCues.map(\.id) == [1])
    }

    /// The silent forced fallback loads with the menu on Off; a hint there would contradict the menu.
    @Test func nothingIsAnnouncedWithoutAPickedTrack() async throws {
        let vm = try makeViewModel()
        vm.subtitleLoadingDidChange(true)
        await waitPastDelay(vm)
        #expect(!vm.showsSubtitleLoadingHint)
        #expect(vm.overlayCues.isEmpty)
    }

    /// A positive subtitle delay looks the cue up before zero.
    @Test func theHintLineCoversEveryPlayhead() {
        #expect(SubtitleLoadingHint.cue.startTime < -1_000_000)
        #expect(SubtitleLoadingHint.cue.endTime > 1_000_000)
    }

    @Test func aTemporarySkipBackWindowGetsNoHint() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.skipBackSubtitleWindow = SkipBackSubtitleWindow.State(origin: 100, landing: 80, streamIndex: 3)
        vm.subtitleLoadingDidChange(true)
        await waitPastDelay(vm)
        #expect(!vm.showsSubtitleLoadingHint)
    }

    /// A republished `true` must neither restart the clock nor be lost after a local reset.
    @Test func aRepeatedTrueKeepsTheClockAndAResetDoesNotSwallowTheNextOne() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.subtitleLoadingDidChange(true)
        let first = vm.subtitleLoadingHintTask
        vm.subtitleLoadingDidChange(true)
        #expect(vm.subtitleLoadingHintTask == first)
        vm.subtitleLoadingDidChange(false)
        vm.subtitleLoadingDidChange(true)
        await waitPastDelay(vm)
        #expect(vm.showsSubtitleLoadingHint)
    }
}

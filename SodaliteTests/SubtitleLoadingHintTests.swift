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
        return PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: RecordingPlaybackService(), userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.subtitleHint.\(UUID().uuidString)")!))
    }

    private func waitPastDelay() async {
        try? await Task.sleep(for: SubtitleLoadingHint.delay + .milliseconds(300))
    }

    @Test func aLoadPastTheDelayShowsTheHintLine() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.activeSubtitleCodec = "ass"
        vm.subtitleLoadingDidChange(true)
        #expect(vm.overlayCues.isEmpty)
        await waitPastDelay()

        #expect(vm.showsSubtitleLoadingHint)
        #expect(vm.overlayCues.count == 1)
        if case .text(let text) = vm.overlayCues.first?.body { #expect(text == SubtitleLoadingHint.text) }
        else { Issue.record("the hint is a text line") }
        #expect(vm.overlaySubtitleCodec == nil)
        #expect(vm.overlayMaxCueDuration == SubtitleLoadingHint.maxCueDuration)
    }

    @Test func aLoadThatEndsInsideTheDelayNeverShowsIt() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.subtitleLoadingDidChange(true)
        vm.subtitleLoadingDidChange(false)
        await waitPastDelay()
        #expect(!vm.showsSubtitleLoadingHint)
    }

    @Test func theFirstCuesReplaceIt() async throws {
        let vm = try makeViewModel()
        vm.activeSubtitleIndex = 3
        vm.subtitleLoadingDidChange(true)
        await waitPastDelay()
        let line = SubtitleCue(id: 1, startTime: 10, endTime: 12, body: .text("Hello"))
        vm.subtitleCues = [line]
        #expect(!vm.showsSubtitleLoadingHint)
        #expect(vm.overlayCues.map(\.id) == [1])
    }

    /// The silent forced fallback loads with the menu on Off; a hint there would contradict the menu.
    @Test func nothingIsAnnouncedWithoutAPickedTrack() async throws {
        let vm = try makeViewModel()
        vm.subtitleLoadingDidChange(true)
        await waitPastDelay()
        #expect(!vm.showsSubtitleLoadingHint)
        #expect(vm.overlayCues.isEmpty)
    }

    @Test func theHintLineCoversEveryPlayhead() {
        let cue = SubtitleLoadingHint.cue(text: "x")
        #expect(cue.startTime == 0)
        #expect(cue.endTime >= 1_000_000)
    }
}

import Testing
import Foundation
@testable import Sodalite

/// Sodalite#251: the end time the transport shows next to the remaining time.
@MainActor
struct PlayerEndTimeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeViewModel(runtimeTicks: Int64? = 36_000_000_000, live: Bool = false) throws -> PlayerViewModel {
        let ticks = runtimeTicks.map { #","RunTimeTicks":\#($0)"# } ?? ""
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"m1","Name":"Film","Type":"Movie"\#(ticks)}"#.utf8))
        return PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: RecordingPlaybackService(), userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.endtime.\(UUID())")!),
            isLiveSession: live)
    }

    @Test("the end is now plus what is left of the title")
    func playingTitle() throws {
        let vm = try makeViewModel()
        vm.remainingSeconds = 600
        #expect(vm.estimatedEnd(now: now) == now + 600)
    }

    @Test("while playing, the end counts from when the remaining time was read, so it cannot flicker")
    func playingAnchorsToTheSample() throws {
        let vm = try makeViewModel()
        vm.isPlaying = true
        vm.remainingSeconds = 600
        vm.remainingSampledAt = now - 0.4
        #expect(vm.estimatedEnd(now: now) == now - 0.4 + 600)
        #expect(vm.estimatedEnd(now: now + 0.9) == now - 0.4 + 600)
    }

    @Test("while paused, the end moves with the clock")
    func pausedFollowsTheClock() throws {
        let vm = try makeViewModel()
        vm.isPlaying = false
        vm.remainingSeconds = 600
        vm.remainingSampledAt = now - 30
        #expect(vm.estimatedEnd(now: now) == now + 600)
    }

    @Test("double speed halves the rest")
    func speedCounts() throws {
        let vm = try makeViewModel()
        vm.remainingSeconds = 600
        vm.activeSpeedIndex = try #require(PlayerViewModel.speedOptions.firstIndex(of: 2.0))
        #expect(vm.estimatedEnd(now: now) == now + 300)
    }

    @Test("while scrubbing the end follows the knob, not the playhead")
    func followsTheScrub() throws {
        let vm = try makeViewModel()
        vm.remainingSeconds = 600
        vm.isScrubbing = true
        vm.scrubProgress = 0.5
        #expect(vm.estimatedEnd(now: now) == now + 1800)
        vm.isScrubbing = false
        #expect(vm.estimatedEnd(now: now) == now + 600)
    }

    @Test("a live channel has no end of its own")
    func liveHasNone() throws {
        let vm = try makeViewModel(live: true)
        vm.remainingSeconds = 600
        #expect(vm.estimatedEnd(now: now) == nil)
    }

    @Test("a pre-roll runs under the movie's item, so it shows no end")
    func prerollHasNone() throws {
        let vm = try makeViewModel()
        vm.remainingSeconds = 600
        vm.isPlayingPreroll = true
        #expect(vm.estimatedEnd(now: now) == nil)
    }

    @Test("an unknown duration shows no end")
    func unknownDuration() throws {
        let vm = try makeViewModel(runtimeTicks: nil)
        vm.remainingSeconds = 0
        #expect(vm.estimatedEnd(now: now) == nil)
    }
}

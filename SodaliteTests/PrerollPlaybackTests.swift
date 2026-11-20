import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Sodalite#244 against a real engine: a 6 s, 64x64 black clip stands in for the server's pre-roll,
/// played from the test bundle. Each test owns its engine, so parallel suites never share one.
@MainActor
struct PrerollPlaybackTests {
    private final class BundleToken {}
    @MainActor final class Outcome { var value: Bool? }

    private var fixture: URL {
        get throws {
            try #require(Bundle(for: BundleToken.self).url(forResource: "preroll-fixture", withExtension: "mp4"))
        }
    }

    private func movie() throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"m1","Name":"Movie","Type":"Movie","RunTimeTicks":72000000000}"#.utf8))
    }

    private func setUp() throws -> (PlayerViewModel, RecordingPlaybackService, AetherEngine) {
        let service = RecordingPlaybackService()
        service.introsByItem["m1"] = [JellyfinItem(seriesStub: "i1", name: "Pre-roll")]
        service.streamURLs["i1"] = try fixture
        let engine = try AetherEngine()
        let prefs = PlaybackPreferences(store: UserDefaults(suiteName: "test.prerollplayback.\(UUID())")!)
        let vm = PlayerViewModel(item: try movie(), startFromBeginning: false, playbackService: service,
                                 userID: "u", preferences: prefs, engine: engine)
        return (vm, service, engine)
    }

    /// Starts the pre-roll session as the real launch does (inside loadTask) and waits for the pill.
    private func startAndWaitForPill(_ vm: PlayerViewModel) async throws -> (Task<Void, Never>, Outcome) {
        let outcome = Outcome()
        let launch = Task { outcome.value = await vm.playPrerollsIfDue() }
        vm.loadTask = launch
        try await waitUntil(seconds: 15) { vm.activeSkipSegment?.kind == .preroll }
        return (launch, outcome)
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(seconds) s")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("an intro plays to its end, then the movie may load, and nothing was reported", .timeLimit(.minutes(1)))
    func introPlaysToItsEnd() async throws {
        let (vm, service, engine) = try setUp()
        let (launch, outcome) = try await startAndWaitForPill(vm)
        #expect(vm.isPlayingPreroll)
        await launch.value
        #expect(outcome.value == true)
        #expect(!vm.isPlayingPreroll)
        #expect(vm.activeSkipSegment == nil)
        #expect(service.progressReports == 0)
        #expect(service.stoppedReports.isEmpty)
        engine.stop()
    }

    @Test("Skip Pre-roll ends the intro at once", .timeLimit(.minutes(1)))
    func skipEndsTheIntro() async throws {
        let (vm, _, engine) = try setUp()
        let (launch, outcome) = try await startAndWaitForPill(vm)
        let skipped = ContinuousClock.now
        vm.skipActiveSegment()
        await launch.value
        #expect(outcome.value == true)
        #expect(ContinuousClock.now - skipped < .seconds(2))
        engine.stop()
    }

    @Test("Back during an intro ends the launch and leaves nothing playing", .timeLimit(.minutes(1)))
    func backDuringIntro() async throws {
        let (vm, service, engine) = try setUp()
        let (launch, outcome) = try await startAndWaitForPill(vm)
        vm.stopPlayback()
        await launch.value
        #expect(outcome.value == false)
        #expect(engine.state != .playing)
        #expect(service.stoppedReports.isEmpty)
    }

    @Test("an engine torn down under a playing intro moves on instead of holding a black screen",
          .timeLimit(.minutes(1)))
    func engineTeardownUnderIntroMovesOn() async throws {
        let (vm, _, engine) = try setUp()
        let (launch, outcome) = try await startAndWaitForPill(vm)
        // What a long trip to the Home screen does to a paused intro: the engine goes idle under it.
        engine.stop()
        let stopped = ContinuousClock.now
        try await waitUntil(seconds: 3) { outcome.value != nil }
        await launch.value
        #expect(outcome.value == true)
        #expect(ContinuousClock.now - stopped < .seconds(3))
    }

    @Test("Back while the intro is still opening leaves nothing playing", .timeLimit(.minutes(1)))
    func backDuringIntroLoad() async throws {
        let (vm, _, engine) = try setUp()
        let outcome = Outcome()
        let launch = Task { outcome.value = await vm.playPrerollsIfDue() }
        vm.loadTask = launch
        try await waitUntil(seconds: 15) { vm.isPlayingPreroll }
        vm.stopPlayback()
        await launch.value
        #expect(outcome.value == false)
        try await Task.sleep(for: .seconds(1))
        #expect(engine.state != .playing)
    }
}

import Testing
import Foundation
@testable import Sodalite

/// Sodalite#244. The mock builds no stream URLs, so a canned intro is fetched but never reaches the
/// engine: these tests pin when the player asks, and what a failed or interrupted ask leaves behind.
@MainActor
struct PrerollSessionTests {
    @MainActor final class Outcome { var value: Bool? }

    private func movie(_ id: String = "m1", resumeTicks: Int64? = nil) throws -> JellyfinItem {
        let userData = resumeTicks.map { #","UserData":{"PlaybackPositionTicks":\#($0),"Played":false}"# } ?? ""
        return try JSONDecoder().decode(
            JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"Movie","Type":"Movie"\#(userData)}"#.utf8))
    }

    private func makeVM(item: JellyfinItem, service: RecordingPlaybackService, prerolls: Bool = true,
                        startFromBeginning: Bool = false) -> PlayerViewModel {
        let prefs = PlaybackPreferences(store: UserDefaults(suiteName: "test.prerollsession.\(UUID())")!)
        prefs.playPrerolls = prerolls
        return PlayerViewModel(item: item, startFromBeginning: startFromBeginning, playbackService: service,
                               userID: "u", preferences: prefs)
    }

    @Test("with the switch off the server is never asked")
    func noIntrosWhenSettingOff() async throws {
        let service = RecordingPlaybackService()
        let vm = makeVM(item: try movie(), service: service, prerolls: false)
        #expect(await vm.playPrerollsIfDue())
        #expect(service.introRequests.isEmpty)
    }

    @Test("a failing ask plays the movie as if there were none")
    func fetchFailureFallsThrough() async throws {
        let service = RecordingPlaybackService()
        service.introsError = URLError(.badServerResponse)
        let vm = makeVM(item: try movie(), service: service)
        #expect(await vm.playPrerollsIfDue())
        #expect(service.introRequests == ["m1"])
        #expect(!vm.isPlayingPreroll)
        #expect(vm.activeSkipSegment == nil)
    }

    @Test("intros without a stream URL are passed over, nothing is left on screen")
    func unplayableIntrosFallThrough() async throws {
        let service = RecordingPlaybackService()
        service.introsByItem["m1"] = [JellyfinItem(seriesStub: "i1", name: "Pre")]
        let vm = makeVM(item: try movie(), service: service)
        #expect(await vm.playPrerollsIfDue())
        #expect(!vm.isPlayingPreroll)
        #expect(vm.activeSkipSegment == nil)
    }

    @Test("a retry, a rung switch or the next episode never asks again")
    func secondStartSkipsIntros() async throws {
        let service = RecordingPlaybackService()
        let vm = makeVM(item: try movie(), service: service)
        _ = await vm.playPrerollsIfDue()
        _ = await vm.playPrerollsIfDue()
        #expect(service.introRequests == ["m1"])
        vm.resetSessionState(.itemSwitch(to: try movie("m2")))
        #expect(vm.prerollsConsumed)
        _ = await vm.playPrerollsIfDue()
        #expect(service.introRequests == ["m1"])
    }

    @Test("a resume asks for nothing, Restart does")
    func resumeStartSkipsIntros() async throws {
        let service = RecordingPlaybackService()
        let resumed = makeVM(item: try movie(resumeTicks: 6_000_000_000), service: service)
        _ = await resumed.playPrerollsIfDue()
        #expect(service.introRequests.isEmpty)
        let restarted = makeVM(item: try movie(resumeTicks: 6_000_000_000), service: service, startFromBeginning: true)
        _ = await restarted.playPrerollsIfDue()
        #expect(service.introRequests == ["m1"])
    }

    @Test("Back while the server is still answering ends the launch, the movie never loads")
    func teardownDuringFetchStopsTheMovie() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.introsGate = gate
        let vm = makeVM(item: try movie(), service: service)
        let outcome = Outcome()
        // The production launch runs in loadTask, which stopPlayback cancels and clears.
        let launch = Task { outcome.value = await vm.playPrerollsIfDue() }
        vm.loadTask = launch
        await gate.arrival(1)
        let started = ContinuousClock.now
        vm.stopPlayback()
        await launch.value
        #expect(outcome.value == false)
        // The cancel ends the ask; waiting out the fetch timeout would hold a dead launch for 3 s.
        #expect(ContinuousClock.now - started < .seconds(2))
        gate.open()
    }

    @Test("a server that never answers costs the fetch timeout, then the movie plays")
    func hangingFetchTimesOut() async throws {
        let service = RecordingPlaybackService()
        let gate = TestGate()
        service.introsGate = gate
        let vm = makeVM(item: try movie(), service: service)
        let started = ContinuousClock.now
        #expect(await vm.playPrerollsIfDue())
        let waited = ContinuousClock.now - started
        #expect(waited >= PrerollPolicy.fetchTimeout)
        #expect(waited < PrerollPolicy.fetchTimeout + .seconds(2))
        gate.open()
    }

    #if os(tvOS)
    @Test("no transport opens over a pre-roll on tvOS")
    func controlsStayClosedDuringPreroll() throws {
        let vm = makeVM(item: try movie(), service: RecordingPlaybackService())
        vm.isPlayingPreroll = true
        vm.showControls = true
        #expect(!vm.showControls)
        vm.isPlayingPreroll = false
        vm.showControls = true
        #expect(vm.showControls)
    }
    #endif

    @Test("Skip Pre-roll with nothing playing is harmless")
    func skipWithoutPrerollIsANoOp() throws {
        let vm = makeVM(item: try movie(), service: RecordingPlaybackService())
        vm.skipCurrentPreroll()
        #expect(!vm.isPlayingPreroll)
    }
}

import Testing
import Foundation
@testable import Sodalite

/// A zap that overtakes a tune still waiting on its PlaybackInfo must not queue behind it (Sodalite#173):
/// Jellyfin probes the provider while answering, and a dead one holds the request for a minute.
@MainActor
struct LiveZapOvertakeTests {
    private let lineupA = LiveChannelLineup(channels: (0..<5).map {
        JellyfinChannel(id: "a\($0)", name: "a\($0)", channelNumber: nil,
                        imageTags: nil, currentProgram: nil, userData: nil)
    })

    private func makeViewModel(liveChannelID: String, playback: RecordingPlaybackService) -> PlayerViewModel {
        let channel = JellyfinChannel(id: liveChannelID, name: liveChannelID, channelNumber: nil,
                                      imageTags: nil, currentProgram: nil, userData: nil)
        return PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: playback,
            userID: "user-overtake",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.zapovertake.\(UUID())")!),
            isLiveSession: true,
            liveChannel: channel)
    }

    private func waitUntil(seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Zaps a1 -> a2 with a2's PlaybackInfo held, then a2 -> a3 with a3's held too.
    private func zapOverAHungTune(
        service: RecordingPlaybackService, holdB: TestGate, holdC: TestGate
    ) async -> (PlayerViewModel, Task<Void, Never>, Task<Void, Never>) {
        service.liveStreamIDs = ["a2": "tuner-a2", "a3": "tuner-a3"]
        service.liveAnswerGates = ["a2": [holdB], "a3": [holdC]]
        let vm = makeViewModel(liveChannelID: "a1", playback: service)
        vm.zapLineup = lineupA
        vm.zapStartPlayback = { try? await vm.loadLiveStream() }
        vm.zapPendingOffset = 1
        let first = Task { await vm.commitZap() }
        await holdB.arrival(1)
        vm.zapPendingOffset = 1
        let second = Task { await vm.commitZap() }
        return (vm, first, second)
    }

    private func finish(_ vm: PlayerViewModel, _ gates: [TestGate], _ tasks: [Task<Void, Never>]) async {
        vm.isTearingDown = true
        gates.forEach { $0.open() }
        for task in tasks { await task.value }
        _ = await LiveTunerGate.shared.settle(timeout: 2)
    }

    @Test func aZapDoesNotWaitForTheTuneItOvertook() async {
        let service = RecordingPlaybackService()
        let holdB = TestGate()
        let holdC = TestGate()
        let (vm, first, second) = await zapOverAHungTune(service: service, holdB: holdB, holdC: holdC)

        let cStarted = await waitUntil { service.livePlaybackInfoRequests.contains("a3") }
        #expect(cStarted, "a3's tune waited for a2's PlaybackInfo")
        #expect(service.closedLiveStreams.isEmpty)
        #expect(vm.liveChannel?.id == "a3")

        await finish(vm, [holdB, holdC], [first, second])
    }

    @Test func theOvertakenTunersLateAnswerIsClosedOnceAndNeverPlays() async {
        let service = RecordingPlaybackService()
        let holdB = TestGate()
        let holdC = TestGate()
        let (vm, first, second) = await zapOverAHungTune(service: service, holdB: holdB, holdC: holdC)
        let cStarted = await waitUntil { service.livePlaybackInfoRequests.contains("a3") }
        #expect(cStarted, "a3's tune waited for a2's PlaybackInfo")
        guard cStarted else {
            await finish(vm, [holdB, holdC], [first, second])
            return
        }

        holdB.open()
        let closed = await waitUntil { service.closedLiveStreams.contains("tuner-a2") }
        _ = await LiveTunerGate.shared.settle(timeout: 2)
        #expect(closed)
        #expect(service.closedLiveStreams.filter { $0 == "tuner-a2" }.count == 1)
        #expect(service.livePlaybackInfoRequests.filter { $0 == "a2" }.count == 1)
        #expect(vm.activeLiveStreamID != "tuner-a2")
        #expect(vm.liveChannel?.id == "a3")

        await finish(vm, [holdC], [first, second])
    }

    /// A -> B -> A on a channel whose first answer is slow: the second open of A must wait for the
    /// first one's answer and its close, however long past the close bound, or that close lands on the
    /// stream the second open is for (Jellyfin's id names the channel, #70).
    @Test func aZapBackToASlowChannelWaitsForItsAbandonedOpen() async {
        let service = RecordingPlaybackService()
        let holdA = TestGate()
        let holdA2 = TestGate()
        let holdB = TestGate()
        service.liveStreamIDs = ["a2": "tuner-a2", "a3": "tuner-a3"]
        service.liveAnswerGates = ["a2": [holdA, holdA2], "a3": [holdB]]
        let vm = makeViewModel(liveChannelID: "a1", playback: service)
        vm.zapLineup = lineupA
        vm.liveTunerCloseSettle = 0.05
        vm.zapStartPlayback = { try? await vm.loadLiveStream() }

        vm.zapPendingOffset = 1
        let toA = Task { await vm.commitZap() }
        await holdA.arrival(1)
        vm.zapPendingOffset = 1
        let toB = Task { await vm.commitZap() }
        await holdB.arrival(1)
        vm.zapPendingOffset = -1
        let backToA = Task { await vm.commitZap() }
        _ = await waitUntil { vm.liveChannel?.id == "a2" }

        try? await Task.sleep(for: .milliseconds(300))
        #expect(service.livePlaybackInfoRequests.filter { $0 == "a2" }.count == 1,
                "the second open of a2 went out before the first one answered")

        holdA.open()
        let reopened = await waitUntil { service.livePlaybackInfoRequests.filter { $0 == "a2" }.count == 2 }
        #expect(reopened)
        #expect(service.closedLiveStreams == ["tuner-a2"])

        holdB.open()
        _ = await waitUntil { service.closedLiveStreams.contains("tuner-a3") }
        _ = await LiveTunerGate.shared.settle(timeout: 2)
        #expect(service.closedLiveStreams.filter { $0 == "tuner-a2" }.count == 1)
        #expect(vm.liveChannel?.id == "a2")

        await finish(vm, [holdA2], [toA, toB, backToA])
    }
}

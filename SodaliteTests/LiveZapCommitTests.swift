import Testing
import Foundation
@testable import Sodalite

@MainActor
struct LiveZapCommitTests {
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
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.zapcommit.\(UUID())")!),
            isLiveSession: true,
            liveChannel: channel)
    }

    @Test func aCommitClosesTheOldSessionThenStartsTheNewChannel() async {
        let service = RecordingPlaybackService()
        let vm = makeViewModel(liveChannelID: "a1", playback: service)
        vm.zapLineup = lineupA
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.activeLiveStreamID = "tuner-1"
        var startedOn: String?
        vm.zapStartPlayback = { startedOn = vm.liveChannel?.id }

        vm.zapPendingOffset = 1
        await vm.commitZap()

        #expect(service.stoppedReports.map(\.liveStreamId) == ["tuner-1"])
        #expect(startedOn == "a2")
        #expect(vm.zapPendingOffset == 0)
        #expect(vm.zapBanner?.channel?.id == "a2")
    }

    @Test func aZapDuringAZapWaitsForTheFirstToSettle() async {
        let vm = makeViewModel(liveChannelID: "a1", playback: RecordingPlaybackService())
        vm.zapLineup = lineupA
        var log: [String] = []
        vm.zapStartPlayback = {
            let id = vm.liveChannel?.id ?? "?"
            log.append("start \(id)")
            try? await Task.sleep(for: .milliseconds(100))
            log.append("end \(id)")
        }
        vm.zapPendingOffset = 1
        let first = Task { await vm.commitZap() }
        try? await Task.sleep(for: .milliseconds(20))
        vm.zapPendingOffset = 1
        await vm.commitZap()
        await first.value
        #expect(log == ["start a2", "end a2", "start a3", "end a3"])
    }

    @Test func aZapDuringTheFirstCloseClosesEachTunerOnce() async {
        let service = RecordingPlaybackService()
        service.stopReportDelay = .milliseconds(100)
        let vm = makeViewModel(liveChannelID: "a1", playback: service)
        vm.zapLineup = lineupA
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.activeLiveStreamID = "tuner-1"
        var started: [String] = []
        vm.zapStartPlayback = { started.append(vm.liveChannel?.id ?? "?") }
        vm.zapPendingOffset = 1
        let first = Task { await vm.commitZap() }
        try? await Task.sleep(for: .milliseconds(20))
        vm.zapPendingOffset = 1
        await vm.commitZap()
        await first.value
        #expect(service.stoppedReports.compactMap(\.liveStreamId) == ["tuner-1"])
        #expect(started == ["a3"])
        #expect(vm.liveChannel?.id == "a3")
    }

    @Test func aZapAfterTeardownDoesNothing() async {
        let service = RecordingPlaybackService()
        let vm = makeViewModel(liveChannelID: "a1", playback: service)
        vm.zapLineup = lineupA
        var started = false
        vm.zapStartPlayback = { started = true }
        vm.isTearingDown = true
        vm.zapPendingOffset = 1
        await vm.commitZap()
        #expect(started == false)
        #expect(vm.liveChannel?.id == "a1")
    }

    @Test func aZapWithNoNeighbourClearsTheBanner() async {
        let vm = makeViewModel(liveChannelID: "a1", playback: RecordingPlaybackService())
        vm.zapLineup = LiveChannelLineup(channels: [])
        vm.zapBanner = LiveZapBanner(channel: nil, direction: 1)
        vm.zapPendingOffset = 1
        await vm.commitZap()
        #expect(vm.zapBanner == nil)
    }
}

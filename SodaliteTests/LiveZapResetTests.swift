import Testing
import Foundation
@testable import Sodalite

@MainActor
struct LiveZapResetTests {
    private let old = JellyfinChannel(id: "old", name: "Old", channelNumber: "1",
                                      imageTags: nil, currentProgram: nil, userData: nil)
    private func new() throws -> JellyfinChannel {
        let program = try JSONDecoder.jellyfinLiveTv.decode(JellyfinProgram.self, from: Data(
            #"{"Id":"p2","Name":"News at Nine","ChannelId":"new"}"#.utf8))
        return JellyfinChannel(id: "new", name: "New", channelNumber: "2",
                               imageTags: nil, currentProgram: program, userData: nil)
    }

    private func makeViewModel(_ service: RecordingPlaybackService) -> PlayerViewModel {
        PlayerViewModel(
            item: JellyfinItem(liveChannel: old, program: nil),
            startFromBeginning: true,
            playbackService: service,
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.zap.\(UUID())")!),
            isLiveSession: true,
            liveChannel: old)
    }

    @Test func theResetLeavesNothingOfTheOldChannel() throws {
        let vm = makeViewModel(RecordingPlaybackService())
        vm.liveSeekableRange = 0...600
        vm.isAtLiveEdge = false
        vm.behindLiveSeconds = 120
        vm.liveRetuneCount = 2
        vm.lastLiveRetuneAt = Date()
        vm.liveRetuneInFlight = true
        vm.liveFirstPlayingAt = Date()
        vm.pendingLiveAudioStreamIndex = 3
        vm.liveProgramWindow = [try new().currentProgram!]
        vm.liveTunerReleasedWhileSuspended = true
        vm.errorMessage = "dead channel"
        vm.showControls = true
        vm.activeSubtitleIndex = 4
        vm.activeAudioIndex = 1

        vm.resetLiveSessionState(switchingTo: try new())

        #expect(vm.liveChannel?.id == "new")
        #expect(vm.item.id == "new")
        #expect(vm.item.name == "News at Nine")
        #expect(vm.liveProgram?.id == "p2")
        #expect(vm.liveSeekableRange == nil)
        #expect(vm.isAtLiveEdge)
        #expect(vm.behindLiveSeconds == 0)
        #expect(vm.liveRetuneCount == 0)
        #expect(vm.lastLiveRetuneAt == nil)
        #expect(vm.liveRetuneInFlight == false)
        #expect(vm.liveFirstPlayingAt == nil)
        #expect(vm.pendingLiveAudioStreamIndex == nil)
        #expect(vm.liveProgramWindow.isEmpty)
        #expect(vm.liveProgramFollow == nil)
        #expect(vm.liveTunerReleasedWhileSuspended == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.showControls == false)
        #expect(vm.activeSubtitleIndex == nil)
        #expect(vm.activeAudioIndex == nil)
    }

    @Test func aRetuneKeepsTheAudioPick() async {
        let service = RecordingPlaybackService()
        let vm = makeViewModel(service)
        vm.pendingLiveAudioStreamIndex = 3
        await vm.closeLiveSessionServerSide()
        #expect(vm.pendingLiveAudioStreamIndex == 3)
    }

    @Test func theCloseReportsThenKillsThenReleases() async {
        let service = RecordingPlaybackService()
        let vm = makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.mediaSourceID = "src-1"
        vm.activeLiveStreamID = "tuner-1"

        await vm.closeLiveSessionServerSide()
        for _ in 0..<200 where service.closedLiveStreams.isEmpty || service.killedEncodings.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(service.stoppedReports.map(\.liveStreamId) == ["tuner-1"])
        #expect(service.killedEncodings == ["ps-1"])
        #expect(service.closedLiveStreams == ["tuner-1"])
        #expect(vm.activeLiveStreamID == nil)
        #expect(vm.hasReportedStart == false)
    }
}

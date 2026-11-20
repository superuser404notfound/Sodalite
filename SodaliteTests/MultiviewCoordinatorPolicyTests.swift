#if os(tvOS)
import Testing
import Foundation
import AetherEngine
@testable import Sodalite

@MainActor
struct MultiviewCoordinatorPolicyTests {
    private func channel(_ id: String) -> JellyfinChannel {
        JellyfinChannel(id: id, name: id, channelNumber: nil, imageTags: nil, currentProgram: nil, userData: nil)
    }

    private func makeVM() throws -> PlayerViewModel {
        let channel = channel("c1")
        return PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: RecordingPlaybackService(),
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.multiviewpolicy.\(UUID())")!),
            isLiveSession: true, liveChannel: channel,
            engine: try AetherEngine())
    }

    @Test("the picker hides channels already on a tile and keeps the lineup order")
    func pickerChannels() {
        let lineup = ["c4", "c1", "c3", "c2", "c5"].map(channel)
        let shown = LiveMultiviewCoordinator.pickerChannels(lineup: lineup, onTiles: ["c1", "c2"])
        #expect(shown.map(\.id) == ["c4", "c3", "c5"])
    }

    @Test("an empty lineup or a lineup fully on tiles offers nothing")
    func pickerChannelsEmpty() {
        #expect(LiveMultiviewCoordinator.pickerChannels(lineup: [], onTiles: ["c1"]).isEmpty)
        #expect(LiveMultiviewCoordinator.pickerChannels(lineup: [channel("c1")], onTiles: ["c1"]).isEmpty)
    }

    @Test("a playing survivor continues in the normal player")
    func exitWithSurvivor() throws {
        let vm = try makeVM()
        #expect(LiveMultiviewCoordinator.exit(after: vm) == .continuing(vm))
    }

    @Test("no survivor, or a stopped one, only closes the grid")
    func exitWithoutSurvivor() throws {
        #expect(LiveMultiviewCoordinator.exit(after: nil) == .close)
        let vm = try makeVM()
        vm.stopPlayback()
        #expect(LiveMultiviewCoordinator.exit(after: vm) == .close)
    }

    @Test("a zap in a tile's full screen steps over the channels the other tiles show")
    func zapSkipsOtherTiles() throws {
        let vm = try makeVM()
        vm.zapLineup = LiveChannelLineup(channels: ["c1", "c2", "c3"].map(channel))
        vm.zapSkipsChannelIDs = { ["c2"] }
        vm.requestZap(by: 1)
        #expect(vm.zapBanner?.channel?.id == "c3")
        vm.stopPlayback()
    }

    @Test("a tile refusal wins over the view model's error text")
    func tileFailureRefusal() {
        let failure = LiveMultiviewCoordinator.tileFailure(
            refusal: .tunerUnavailable, errorTitle: "Server error", errorMessage: "HTTP 500")
        #expect(failure?.title == LiveTuneRefusal.tunerUnavailable.title)
        #expect(failure?.body == LiveTuneRefusal.tunerUnavailable.body)
    }

    @Test("without a refusal the view model's error shows, and no error means no failure")
    func tileFailureError() {
        let failure = LiveMultiviewCoordinator.tileFailure(refusal: nil, errorTitle: "Channel unavailable", errorMessage: "Offline")
        #expect(failure?.title == "Channel unavailable")
        #expect(failure?.body == "Offline")
        #expect(LiveMultiviewCoordinator.tileFailure(refusal: nil, errorTitle: "Stale title", errorMessage: nil) == nil)
    }
}
#endif

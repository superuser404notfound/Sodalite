import Testing
import Foundation
@testable import Sodalite

/// Sodalite#204: a tune asks Jellyfin for the channel's provider URL without opening a tuner first, and
/// only a channel whose unopened answer names no playlist goes on to the open it always paid.
@MainActor
struct LiveUnopenedPlaybackInfoTests {

    private func makeViewModel(channelID: String, playback: RecordingPlaybackService) -> PlayerViewModel {
        let channel = JellyfinChannel(id: channelID, name: channelID, channelNumber: nil,
                                      imageTags: nil, currentProgram: nil, userData: nil)
        return PlayerViewModel(
            item: JellyfinItem(liveChannel: channel, program: nil),
            startFromBeginning: true,
            playbackService: playback,
            userID: "user-unopened",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.unopened.\(UUID())")!),
            isLiveSession: true,
            liveChannel: channel)
    }

    @Test func aChannelWithoutAPlaylistOpensAndIsNotAskedTwice() async {
        let channelID = "hdhr-\(UUID().uuidString)"
        let service = RecordingPlaybackService()
        service.unopenedPaths = [channelID: "http://192.168.1.60:5004/auto/v5.1"]
        service.liveStreamIDs = [channelID: "tuner-\(channelID)"]

        let first = makeViewModel(channelID: channelID, playback: service)
        try? await first.loadLiveStream()
        #expect(service.unopenedLivePlaybackInfoRequests == [channelID])
        let opensOnFirstTune = service.livePlaybackInfoRequests.count
        #expect(opensOnFirstTune > 0, "a channel without a playlist still opens its tuner")

        let second = makeViewModel(channelID: channelID, playback: service)
        try? await second.loadLiveStream()
        #expect(service.unopenedLivePlaybackInfoRequests == [channelID],
                "the unopened answer named no playlist once, so the next tune opens straight away")
        #expect(service.livePlaybackInfoRequests.count == 2 * opensOnFirstTune)
        _ = await LiveTunerGate.shared.settle(timeout: 2)
    }
}

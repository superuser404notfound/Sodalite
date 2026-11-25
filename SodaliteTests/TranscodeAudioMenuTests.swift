import AetherEngine
import Foundation
import Testing
@testable import Sodalite

/// Sodalite#253: Jellyfin's HLS master carries only the audio PlaybackInfo named, so under a transcode
/// the engine lists one track. The menu therefore lists the source's own audio streams, keyed by
/// Jellyfin index, and a pick reopens the transcode with that index.
@MainActor
struct TranscodeAudioMenuTests {
    private static let sourceJSON = #"""
    {"Id":"src-1","Container":"mkv","Bitrate":20000000,
     "TranscodingUrl":"/videos/ep-1/master.m3u8?MediaSourceId=src-1&AudioStreamIndex=1&SubtitleStreamIndex=-1",
     "MediaStreams":[
      {"Index":0,"Type":"Video","Codec":"hevc"},
      {"Index":1,"Type":"Audio","Codec":"eac3","Language":"deu","Channels":6,"IsDefault":true},
      {"Index":2,"Type":"Audio","Codec":"eac3","Language":"eng","Channels":6,"IsDefault":false},
      {"Index":3,"Type":"Subtitle","Codec":"PGSSUB","Language":"deu"}]}
    """#

    private func source(_ json: String = sourceJSON) throws -> PlaybackMediaSource {
        try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(json.utf8))
    }

    private func makeViewModel(_ service: RecordingPlaybackService) throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","RunTimeTicks":36000000000}"#.utf8))
        let vm = PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: service, userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.transcodeAudio.\(UUID().uuidString)")!))
        vm.activePlayMethod = .transcode
        vm.activePlaybackSource = try source()
        vm.streamingQuality = .mbps4
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.mediaSourceID = "src-1"
        vm.playbackTime = 600
        return vm
    }

    private func settle(_ service: RecordingPlaybackService) async {
        for _ in 0..<300 where service.killedEncodings.isEmpty || service.requestedAudioIndexes.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func theMenuListsEveryAudioStreamByJellyfinIndex() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        #expect(vm.displayAudioTracks.map(\.id) == [1, 2])
        #expect(vm.displayAudioTracks.map(\.language) == ["deu", "eng"])
        #expect(vm.transcodedAudioStreamIndex == 1)
        vm.stopPlayback()
    }

    @Test func directPlayKeepsTheEngineList() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.activePlayMethod = .directPlay
        #expect(vm.transcodeAudioTracks == nil)
        vm.stopPlayback()
    }

    @Test func aPickReopensTheTranscodeWithThatIndexAtTheSameRung() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.activeAudioIndex = 1
        vm.activeSubtitleIndex = 3

        vm.selectAudioTrack(id: 2, userInitiated: true)
        #expect(vm.pendingSessionCarry?.subtitleStreamIndex == 3)
        #expect(vm.pendingSessionCarry?.reappliesSubtitleRule == true)
        await settle(service)

        #expect(service.killedEncodings == ["ps-1"])
        #expect(service.stoppedReports.first?.positionTicks == 6_000_000_000)
        #expect(service.requestedAudioIndexes == [2])
        #expect(service.requestedCaps == [4_000_000])
        #expect(vm.streamingQuality == .mbps4)
        vm.stopPlayback()
    }

    @Test func pickingThePlayingTrackDoesNothing() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.activeAudioIndex = 1
        vm.selectAudioTrack(id: 1, userInitiated: true)
        vm.selectAudioTrack(id: 9, userInitiated: true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(service.playbackInfoRequests.isEmpty)
        #expect(service.killedEncodings.isEmpty)
        vm.stopPlayback()
    }

    /// The engine's one track has no language under a transcode, so the rung switch used to lose the
    /// audio the viewer was hearing.
    @Test func aRungSwitchKeepsTheTranscodeAudio() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.activeAudioIndex = 2
        vm.selectStreamingQuality(.mbps2)
        await settle(service)
        #expect(service.requestedAudioIndexes == [2])
        vm.stopPlayback()
    }

    @Test func theURLsAudioIndexIsRead() {
        #expect(PlayerViewModel.transcodeAudioStreamIndex(
            transcodingURL: "/videos/x/master.m3u8?audioStreamIndex=4&VideoCodec=hevc") == 4)
        #expect(PlayerViewModel.transcodeAudioStreamIndex(transcodingURL: "/videos/x/master.m3u8") == nil)
        #expect(PlayerViewModel.transcodeAudioStreamIndex(transcodingURL: nil) == nil)
    }

    // MARK: - Start audio

    @Test func thePreferredLanguageIsAskedForWhenTheServerPlaysAnother() throws {
        #expect(PlayerViewModel.transcodeStartAudioIndex(entry: nil, preferredLanguage: "en", source: try source()) == 2)
    }

    @Test func theServersPickStandsWhenItSpeaksThePreferredLanguage() throws {
        #expect(PlayerViewModel.transcodeStartAudioIndex(entry: nil, preferredLanguage: "de", source: try source()) == nil)
        #expect(PlayerViewModel.transcodeStartAudioIndex(entry: nil, preferredLanguage: "fr", source: try source()) == nil)
        #expect(PlayerViewModel.transcodeStartAudioIndex(entry: nil, preferredLanguage: nil, source: try source()) == nil)
    }

    @Test func aRememberedTrackOutranksThePreferredLanguage() throws {
        let english = TrackSelectionMatcher.audioSignature(
            TrackInfo(id: 0, name: "", codec: "eac3", language: "eng", channels: 6, isDefault: false))
        let entry = TrackMemoryEntry(subtitle: nil, audio: english, updatedAt: .now)
        #expect(PlayerViewModel.transcodeStartAudioIndex(entry: entry, preferredLanguage: "de", source: try source()) == 2)
    }

    @Test func aSourceWithOneAudioIsLeftAlone() throws {
        let single = Self.sourceJSON.replacingOccurrences(
            of: #"{"Index":2,"Type":"Audio","Codec":"eac3","Language":"eng","Channels":6,"IsDefault":false},"#, with: "")
        #expect(PlayerViewModel.transcodeStartAudioIndex(entry: nil, preferredLanguage: "en", source: try source(single)) == nil)
    }
}

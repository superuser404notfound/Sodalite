import Combine
import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: a rung switch is a new stream. The old server session must close (report + encode
/// kill, or the server keeps an ffmpeg running), and the new one must start where the viewer was.
@MainActor
struct StreamingQualitySwitchTests {
    private func makeViewModel(_ service: RecordingPlaybackService) throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","RunTimeTicks":36000000000}"#.utf8))
        return PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: service, userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.qualitySwitch.\(UUID().uuidString)")!))
    }

    private func settle(_ service: RecordingPlaybackService, kills: Int, infos: Int) async {
        for _ in 0..<300 where service.killedEncodings.count < kills || service.requestedCaps.count < infos {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func aSwitchClosesTheOldSessionAndReopensAtTheNewCap() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .original
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.mediaSourceID = "src-1"
        vm.playbackTime = 1200

        vm.selectStreamingQuality(.mbps4)
        await settle(service, kills: 1, infos: 1)

        #expect(vm.streamingQuality == .mbps4)
        #expect(service.stoppedReports.map(\.playSessionId) == ["ps-1"])
        #expect(service.stoppedReports.first?.positionTicks == 12_000_000_000)
        #expect(service.killedEncodings == ["ps-1"])
        #expect(service.requestedCaps == [4_000_000])
    }

    @Test func pickingTheActiveRungDoesNothing() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .mbps10
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"

        vm.selectStreamingQuality(.mbps10)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(service.stoppedReports.isEmpty)
        #expect(service.killedEncodings.isEmpty)
        #expect(service.requestedCaps.isEmpty)
    }

    @Test func twoSwitchesCloseEachSessionOnce() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .original
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"

        vm.selectStreamingQuality(.mbps10)
        // What the reopened session would have been given by the server.
        vm.hasReportedStart = true
        vm.playSessionID = "ps-2"
        vm.selectStreamingQuality(.mbps2)
        await settle(service, kills: 2, infos: 2)

        #expect(vm.streamingQuality == .mbps2)
        // The two closes run detached, so their order is not the test's to pin.
        #expect(service.killedEncodings.sorted() == ["ps-1", "ps-2"])
        #expect(service.requestedCaps.last == 2_000_000)
    }

    // MARK: - Final review findings

    /// The engine's stop zeroes the clock, and a second pick before the reload has started must not
    /// read that zero as the viewer's position.
    @Test func aSecondPickBeforeTheReloadStartsKeepsTheOriginalSecond() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.streamingQuality = .original
        vm.playbackTime = 1200

        vm.selectStreamingQuality(.mbps10)
        vm.playbackTime = 0
        vm.selectStreamingQuality(.mbps4)

        #expect(vm.resumeOverrideSeconds == 1200)
    }

    /// Sinks left armed through the engine stop copy its zeroed clock into the transport bar.
    @Test func aSwitchStopsObservingBeforeTheEngineStops() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.streamingQuality = .original
        vm.playbackTime = 600
        let subject = PassthroughSubject<Double, Never>()
        subject.sink { vm.playbackTime = $0 }.store(in: &vm.cancellables)

        vm.selectStreamingQuality(.mbps4)
        subject.send(0)

        #expect(vm.playbackTime == 600)
    }

    /// A pick during the credits must not leave the auto-advance racing the reload.
    @Test func aSwitchStopsTheNextEpisodeCountdown() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.streamingQuality = .original
        vm.isCountdownActive = true
        vm.nextEpisodeTimer = Task { try? await Task.sleep(for: .seconds(60)) }

        vm.selectStreamingQuality(.mbps4)

        #expect(vm.nextEpisodeTimer == nil)
        #expect(!vm.isCountdownActive)
    }

    /// The successor warm is labelled with the rung it was fetched at, not the one current when it
    /// lands, or a pick during the warm would hand the next episode a stream at the old cap.
    @Test func aSuccessorWarmKeepsTheRungItWasFetchedAt() async throws {
        let service = RecordingPlaybackService()
        service.delayedItemIDs = ["ep-2"]
        let vm = try makeViewModel(service)
        vm.streamingQuality = .original
        let next = try JSONDecoder().decode(
            JellyfinItem.self, from: Data(#"{"Id":"ep-2","Name":"Next","Type":"Episode"}"#.utf8))
        vm.nextEpisode = next

        let warm = Task { await vm.warmSuccessor(next) }
        try await Task.sleep(for: .milliseconds(40))
        vm.streamingQuality = .mbps4
        await warm.value

        #expect(vm.cachedPlaybackInfo?.matching("ep-2", quality: .mbps4) == nil)
        #expect(vm.cachedPlaybackInfo?.matching("ep-2", quality: .original) != nil)
    }

    /// After a switch the successor is warmed again, at the new rung.
    @Test func aSwitchLetsTheSuccessorBeWarmedAgain() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.streamingQuality = .original
        vm.hasWarmedSuccessor = true

        vm.selectStreamingQuality(.mbps4)

        #expect(!vm.hasWarmedSuccessor)
    }

    /// The indexes only count for the source the request names, so a switch pins the one it played.
    @Test func aSwitchPinsTheSourceItWasPlaying() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .original
        vm.mediaSourceID = "src-1"

        vm.selectStreamingQuality(.mbps4)
        await settle(service, kills: 0, infos: 1)

        #expect(service.requestedMediaSourceIDs.first == "src-1")
    }

    /// A server that picked a subtitle of its own burns it in, and prepares that by extracting every
    /// subtitle from the whole file first. The start asks once more, now naming the source it got.
    @Test func aServerBurnInIsAskedAgainWithTheSourcePinned() async throws {
        let service = RecordingPlaybackService()
        service.transcodingURLWhenUnpinned = "/videos/ep-1/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Encode"
        let vm = try makeViewModel(service)
        vm.streamingQuality = .mbps4

        await vm.startPlayback()

        #expect(service.requestedMediaSourceIDs == [nil, "src-ep-1"])
    }

    @Test func noBurnInMeansOneRequest() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .mbps4

        await vm.startPlayback()

        #expect(service.requestedMediaSourceIDs == [nil])
    }

    @Test func aBurnInIsReadOffTheTranscodeURL() {
        #expect(PlayerViewModel.serverBurnsInSubtitle("/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Encode"))
        #expect(PlayerViewModel.serverBurnsInSubtitle("/master.m3u8?subtitlestreamindex=0&subtitlemethod=encode"))
        #expect(!PlayerViewModel.serverBurnsInSubtitle("/master.m3u8?SubtitleMethod=External"))
        #expect(!PlayerViewModel.serverBurnsInSubtitle(nil))
    }

    /// Jellyfin writes `SubtitleMethod=Encode` into every transcode URL, subtitle or not: Encode is its
    /// enum's default (device log 2026-09-28). Only a named subtitle stream is a burn-in.
    @Test func encodeWithoutASubtitleStreamIsNoBurnIn() {
        #expect(!PlayerViewModel.serverBurnsInSubtitle("/master.m3u8?AudioStreamIndex=1&SubtitleMethod=Encode"))
        #expect(!PlayerViewModel.serverBurnsInSubtitle("/master.m3u8?SubtitleStreamIndex=-1&SubtitleMethod=Encode"))
    }

    /// A capped stream carries one audio track, so the reopen names the one the viewer had.
    @Test func theReopenAsksForThePendingAudioStream() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.streamingQuality = .mbps4
        vm.pendingAudioStreamIndex = 2

        await vm.startPlayback()

        #expect(service.requestedAudioIndexes == [2])
        #expect(vm.pendingAudioStreamIndex == nil)
    }
}

@Suite("Jellyfin audio stream for an engine track")
struct JellyfinAudioStreamIndexTests {
    private func streams(_ json: String) throws -> [MediaStream] {
        try JSONDecoder().decode([MediaStream].self, from: Data(json.utf8))
    }

    private let twoLanguages = #"""
    [{"Index":0,"Type":"Video","Codec":"hevc"},
     {"Index":1,"Type":"Audio","Codec":"eac3","Language":"eng","Channels":6,"IsDefault":true},
     {"Index":2,"Type":"Audio","Codec":"aac","Language":"jpn","Channels":2},
     {"Index":3,"Type":"Audio","Codec":"truehd","Language":"jpn","Channels":8}]
    """#

    @Test func aLanguageWithOneStreamPicksIt() throws {
        #expect(PlayerViewModel.jellyfinAudioStreamIndex(
            language: "eng", channels: 2, codec: "aac", in: try streams(twoLanguages)) == 1)
    }

    @Test func twoStreamsOfALanguageAreToldApartByChannels() throws {
        #expect(PlayerViewModel.jellyfinAudioStreamIndex(
            language: "jpn", channels: 8, codec: "truehd", in: try streams(twoLanguages)) == 3)
        #expect(PlayerViewModel.jellyfinAudioStreamIndex(
            language: "JPN", channels: 2, codec: "aac", in: try streams(twoLanguages)) == 2)
    }

    @Test func noLanguageOrNoMatchNamesNothing() throws {
        #expect(PlayerViewModel.jellyfinAudioStreamIndex(
            language: nil, channels: 2, codec: "aac", in: try streams(twoLanguages)) == nil)
        #expect(PlayerViewModel.jellyfinAudioStreamIndex(
            language: "ger", channels: 2, codec: "aac", in: try streams(twoLanguages)) == nil)
        #expect(PlayerViewModel.jellyfinAudioStreamIndex(
            language: "eng", channels: 2, codec: "aac", in: nil) == nil)
    }
}

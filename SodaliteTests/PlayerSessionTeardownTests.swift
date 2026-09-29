import Testing
import Foundation
@testable import Sodalite

/// A Back press reaches `stopPlayback()` twice (dismissPlayer, then viewWillDisappear), and the
/// second pass reads a playhead `player.stop()` already zeroed. Both reports reach Jellyfin, so the
/// raw one could land after the completion-aware one and put a finished episode back on the Continue
/// Watching shelf. A stop for a session whose start never went out writes 0 over the resume point.
/// Audit 2026-09-25 PLAYER-CORE-2/3/4.
@MainActor
struct PlayerSessionTeardownTests {

    private func item() throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"ep-1","Name":"Episode","Type":"Episode","RunTimeTicks":36000000000}"#.utf8)
        )
    }

    private func makeViewModel(_ service: RecordingPlaybackService) throws -> PlayerViewModel {
        let suite = "test.playerTeardown.\(UUID().uuidString)"
        return PlayerViewModel(
            item: try item(),
            startFromBeginning: false,
            playbackService: service,
            userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: suite)!)
        )
    }

    /// The detached stop work finishes on its own schedule; wait for the encoding kill, which always
    /// runs last, then give a stray second pass the same time to show up.
    private func settle(_ service: RecordingPlaybackService, kills: Int) async {
        for _ in 0..<200 where service.killedEncodings.count < kills {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    @Test func aSecondStopInTheSameSessionSendsNothing() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.mediaSourceID = "src-1"
        vm.playbackTime = 1200

        vm.stopPlayback()
        // What the engine leaves behind once stopped: the second pass must not report from this.
        vm.playbackTime = 30
        vm.stopPlayback()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.count == 1)
        #expect(service.stoppedReports.first?.positionTicks == 12_000_000_000)
        #expect(service.killedEncodings == ["ps-1"])
    }

    @Test func aSessionThatNeverReportedAStartSendsNoStopButStillKillsItsEncoding() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.playSessionID = "ps-1"

        vm.stopPlayback()
        await settle(service, kills: 1)

        #expect(service.stoppedReports.isEmpty)
        #expect(service.killedEncodings == ["ps-1"])
    }

    @Test func aNewSessionOnTheSameViewModelStopsAgain() async throws {
        let service = RecordingPlaybackService()
        let vm = try makeViewModel(service)
        vm.hasReportedStart = true
        vm.playSessionID = "ps-1"
        vm.stopPlayback()
        await settle(service, kills: 1)

        // What startPlayback does at entry for a retry on the same view model.
        vm.didStopPlayback = false
        vm.hasReportedStart = true
        vm.playSessionID = "ps-2"
        vm.stopPlayback()
        await settle(service, kills: 2)

        #expect(service.stoppedReports.map(\.playSessionId) == ["ps-1", "ps-2"])
    }

    /// Back during the `reportStart` round trip: the tail of startPlayback resumes after the stop and
    /// would otherwise arm a timer nothing ever cancels.
    @Test func progressReportingIsNotArmedAfterTeardown() throws {
        let vm = try makeViewModel(RecordingPlaybackService())
        vm.stopPlayback()
        vm.startProgressReporting()
        #expect(vm.progressTimer == nil)
    }
}

final class RecordingPlaybackService: JellyfinPlaybackServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _stoppedReports: [PlaybackStopReport] = []
    private var _killedEncodings: [String] = []
    private var _closedLiveStreams: [String] = []
    private var _playbackInfoRequests: [String] = []
    private var _requestedCaps: [Int?] = []
    private var _requestedAudioIndexes: [Int?] = []
    private var _requestedMediaSourceIDs: [String?] = []
    /// A TranscodingUrl the server answers with while the request pins no source, to stand in for a
    /// server that picked and burns in a subtitle of its own.
    var transcodingURLWhenUnpinned: String?
    /// Item ids whose PlaybackInfo answers only after a short delay, so a test can act in between.
    var delayedItemIDs: Set<String> = []
    /// Item ids whose PlaybackInfo never answers (until the caller's task is cancelled).
    var hangingItemIDs: Set<String> = []
    /// Item ids whose PlaybackInfo answers late and ignores cancellation, like a request already on
    /// the wire when the session is torn down.
    var uncancellableDelayItemIDs: Set<String> = []

    var stoppedReports: [PlaybackStopReport] { lock.withLock { _stoppedReports } }
    var killedEncodings: [String] { lock.withLock { _killedEncodings } }
    var closedLiveStreams: [String] { lock.withLock { _closedLiveStreams } }
    var playbackInfoRequests: [String] { lock.withLock { _playbackInfoRequests } }
    /// The `MaxStreamingBitrate` of every PlaybackInfo profile, in request order (Sodalite#87).
    var requestedCaps: [Int?] { lock.withLock { _requestedCaps } }
    var requestedAudioIndexes: [Int?] { lock.withLock { _requestedAudioIndexes } }
    var requestedMediaSourceIDs: [String?] { lock.withLock { _requestedMediaSourceIDs } }

    var baseURL: URL? { nil }
    var deviceID: String { "device" }

    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws {
        lock.withLock { _stoppedReports.append(report) }
    }
    func stopActiveEncodings(playSessionID: String) async throws {
        lock.withLock { _killedEncodings.append(playSessionID) }
    }
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse {
        try await getPlaybackInfo(itemID: itemID, userID: userID, profile: profile,
                                  mediaSourceID: nil, audioStreamIndex: nil)
    }
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?,
                         mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse {
        let cap = profile?["MaxStreamingBitrate"] as? Int
        lock.withLock {
            _playbackInfoRequests.append(itemID)
            _requestedCaps.append(cap)
            _requestedAudioIndexes.append(audioStreamIndex)
            _requestedMediaSourceIDs.append(mediaSourceID)
        }
        if delayedItemIDs.contains(itemID) {
            try await Task.sleep(for: .milliseconds(150))
        }
        if uncancellableDelayItemIDs.contains(itemID) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { done.resume() }
            }
        }
        if hangingItemIDs.contains(itemID) {
            try await Task.sleep(for: .seconds(60))
        }
        let transcoding = mediaSourceID == nil ? transcodingURLWhenUnpinned.map { #","TranscodingUrl":"\#($0)""# } ?? "" : ""
        return try JSONDecoder().decode(
            PlaybackInfoResponse.self,
            from: Data(#"{"MediaSources":[{"Id":"src-\#(itemID)","Container":"flac"\#(transcoding)}],"PlaySessionId":"ps-\#(itemID)"}"#.utf8)
        )
    }

    private struct NotUsed: Error {}
    func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]?, maxStreamingBitrate: Int, enableDirectPlay: Bool) async throws -> PlaybackInfoResponse { throw NotUsed() }
    func reportPlaybackStart(_ report: PlaybackStartReport) async throws {}
    func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws {}
    func closeLiveStream(liveStreamID: String) async throws {
        lock.withLock { _closedLiveStreams.append(liveStreamID) }
    }
    func getSessions() async throws -> [JellyfinSessionInfo] { [] }
    func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] { [] }
    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] { [] }
    func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments { throw NotUsed() }
    func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? { nil }
    func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? { nil }
    func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? { nil }
    func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL? { nil }
    func buildTrickplayTileURL(itemID: String, width: Int, tileIndex: Int) -> URL? { nil }
    func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo] { [] }
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {}
    func deleteSubtitle(itemID: String, index: Int) async throws {}
    func buildTranscodeURL(relativePath: String) -> URL? { nil }
    func buildLiveStreamFileURL(sourcePath: String) -> URL? { nil }
}

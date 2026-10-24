import Testing
import Foundation
@testable import Sodalite

/// AetherEngine#551 warms a source before anything asks to play it, and the engine adopts warmed
/// bytes by EXACT URL. So the URL a warm asks for and the URL playback later opens have to be the
/// same string, which is why both now come out of one resolver instead of two call sites that
/// happen to agree today.
@Suite("Playback stream selection (AE#551)")
struct PlaybackStreamSelectionTests {

    struct NotUsed: Error {}

    /// Builds the same URLs the real service builds, because the shape of the URL is the subject
    /// here: which id goes in the path, which goes in the query, and whether `Static` is set.
    final class MockService: JellyfinPlaybackServiceProtocol, @unchecked Sendable {
        var baseURL: URL? { URL(string: "http://server") }
        var deviceID: String { "device" }

        func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? {
            var s = "http://server/Videos/\(itemID)/stream.\(container ?? "mp4")?MediaSourceId=\(mediaSourceID)&api_key=t"
            if isStatic { s += "&Static=true" }
            return URL(string: s)
        }
        func buildTranscodeURL(relativePath: String) -> URL? {
            URL(string: "http://server" + relativePath)
        }

        func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse { throw NotUsed() }
        func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]?, maxStreamingBitrate: Int, enableDirectPlay: Bool, autoOpenLiveStream: Bool) async throws -> PlaybackInfoResponse { throw NotUsed() }
        func reportPlaybackStart(_ report: PlaybackStartReport) async throws {}
        func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws {}
        func reportPlaybackStopped(_ report: PlaybackStopReport) async throws {}
        func closeLiveStream(liveStreamID: String) async throws {}
        func stopActiveEncodings(playSessionID: String) async throws {}
        func getSessions() async throws -> [JellyfinSessionInfo] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] { [] }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] { [] }
        func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments { throw NotUsed() }
        func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? { nil }
        func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? { nil }
        func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL? { nil }
        func buildTrickplayTileURL(itemID: String, width: Int, tileIndex: Int) -> URL? { nil }
        func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo] { [] }
        func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {}
        func deleteSubtitle(itemID: String, index: Int) async throws {}
        func buildLiveStreamFileURL(sourcePath: String) -> URL? { nil }
    }

    private func source(_ json: String) throws -> PlaybackMediaSource {
        try JSONDecoder().decode(PlaybackMediaSource.self, from: Data(json.utf8))
    }

    private func response(_ json: String) throws -> PlaybackInfoResponse {
        try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
    }

    @Test("a direct-play source resolves to the static file URL")
    func directPlayIsStatic() throws {
        let resolved = try #require(PlaybackStreamSelection.resolve(
            itemID: "item1",
            source: source(#"{"Id":"src9","Container":"mkv","SupportsDirectPlay":true}"#),
            using: MockService()))

        #expect(resolved.method == .directPlay)
        #expect(resolved.url.absoluteString.contains("Static=true"))
        // The path carries the ITEM, the query carries the SOURCE. Crossing them is a 400 from
        // Jellyfin (Sodalite#71), so it is worth pinning here rather than only at the call site.
        #expect(resolved.url.absoluteString.contains("/Videos/item1/stream.mkv"))
        #expect(resolved.url.absoluteString.contains("MediaSourceId=src9"))
        #expect(resolved.isWarmable)
    }

    @Test("a direct-stream source resolves to the remuxing URL, not the static one")
    func directStreamIsNotStatic() throws {
        let resolved = try #require(PlaybackStreamSelection.resolve(
            itemID: "item1",
            source: source(#"{"Id":"src1","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":true}"#),
            using: MockService()))

        #expect(resolved.method == .directStream)
        #expect(!resolved.url.absoluteString.contains("Static=true"))
        #expect(resolved.isWarmable)
    }

    /// The expensive route is also the useless one. Asking for a transcode URL starts an ffmpeg
    /// session on the server for an item nobody is watching, and what comes back is a playlist the
    /// engine hands to AVPlayer, where it issues no requests of its own and there is nothing for a
    /// later load to adopt.
    @Test("a transcode source resolves, and is not warmable")
    func transcodeIsNotWarmable() throws {
        let resolved = try #require(PlaybackStreamSelection.resolve(
            itemID: "item1",
            source: source(#"{"Id":"src1","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":false,"TranscodingUrl":"/videos/item1/master.m3u8?x=1"}"#),
            using: MockService()))

        #expect(resolved.method == .transcode)
        #expect(!resolved.isWarmable, "warming a transcode URL would start a transcode nobody asked for")
    }

    @Test("a source with no route at all resolves to nothing")
    func noRouteResolvesToNil() throws {
        let resolved = try PlaybackStreamSelection.resolve(
            itemID: "item1",
            source: source(#"{"Id":"src1","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":false}"#),
            using: MockService())

        #expect(resolved == nil)
    }

    /// The warm runs before anything has expressed a preference between versions, so it has to pick
    /// the same source `startPlayback` falls back to when its own preference does not match.
    @Test("the default source is the first one the server listed")
    func defaultSourceIsTheFirst() throws {
        let info = try response(#"{"MediaSources":[{"Id":"a","Container":"mkv","SupportsDirectPlay":true},{"Id":"b","Container":"mp4","SupportsDirectPlay":true}],"PlaySessionId":"ps"}"#)
        #expect(PlaybackStreamSelection.defaultSource(in: info)?.id == "a")
    }

    @Test("a response with no sources warms nothing")
    func emptyResponseHasNoSource() throws {
        let info = try response(#"{"MediaSources":[],"PlaySessionId":"ps"}"#)
        #expect(PlaybackStreamSelection.defaultSource(in: info) == nil)
    }
}

/// When the successor is warmed. The window is deliberately not the overlay's own (AE#551).
@Suite("Successor warm lead (AE#551)")
struct SuccessorWarmLeadTests {

    /// Without a marker the overlay opens 30 s from the end, and a warm armed there would still be
    /// on the wire when the switch happens on a slow link.
    @Test("without an outro marker the warm arms well before the overlay does")
    func warmArmsBeforeTheOverlayWithoutMarker() {
        let warmsAt90 = NextEpisodePolicy.shouldWarmSuccessor(
            outroStartSeconds: nil, sourceTime: 1000, remainingSeconds: 90)
        let overlayAt90 = NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 1000, remainingSeconds: 90)

        #expect(warmsAt90)
        #expect(!overlayAt90, "the overlay is not the subject here, the lead in front of it is")
    }

    @Test("the warm is not armed in the middle of an episode")
    func noWarmMidEpisode() {
        #expect(!NextEpisodePolicy.shouldWarmSuccessor(
            outroStartSeconds: nil, sourceTime: 600, remainingSeconds: 900))
    }

    /// With a marker the switch can BE the marker: outro auto-skip jumps at it. So the lead is
    /// measured back from the marker rather than from the end of the source, or a viewer with that
    /// setting on would get no lead at all.
    @Test("with an outro marker the lead is measured back from the marker")
    func leadRunsBackFromTheMarker() {
        let marker: Double = 2400
        #expect(NextEpisodePolicy.shouldWarmSuccessor(
            outroStartSeconds: marker, sourceTime: marker - 60, remainingSeconds: 300))
        #expect(!NextEpisodePolicy.shouldWarmSuccessor(
            outroStartSeconds: marker, sourceTime: marker - 300, remainingSeconds: 600))
    }

    /// The property that has to hold however the two windows are tuned: the warm is never armed
    /// later than the switch it exists for. A lead shorter than the overlay window would warm into
    /// a transition that has already started.
    @Test("the warm is armed wherever the switch window is open, marker or not")
    func warmCoversEveryTriggerWindow() {
        for marker in [nil, 300.0, 2400.0] as [Double?] {
            for sourceTime in stride(from: 0.0, through: 3000.0, by: 60.0) {
                for remaining in stride(from: 0.0, through: 600.0, by: 15.0) {
                    let switching = NextEpisodePolicy.isInsideTriggerWindow(
                        outroStartSeconds: marker, sourceTime: sourceTime, remainingSeconds: remaining)
                    guard switching else { continue }
                    #expect(NextEpisodePolicy.shouldWarmSuccessor(
                        outroStartSeconds: marker, sourceTime: sourceTime, remainingSeconds: remaining),
                            "switch window open at marker=\(String(describing: marker)) t=\(sourceTime) rem=\(remaining) but no warm was armed")
                }
            }
        }
    }
}

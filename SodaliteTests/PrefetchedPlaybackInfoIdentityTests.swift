import Testing
import Foundation
@testable import Sodalite

/// A PlaybackInfo response describes ONE item. Handed to a different one it builds
/// `/Videos/{other}/stream.mkv?MediaSourceId={this}`, and Jellyfin answers that pair with HTTP 400
/// (measured against a live server: the matching pair returns 206, the crossed pair 400), which the
/// engine surfaces as "origins answered HTTP 400 for the source" (Sodalite#71).
///
/// The detail screen prefetches that response for the play target, so the response and the id it was
/// fetched for must travel together. `currentEpisodeID` is not that id: `refreshResumePosition()`
/// moves it to whatever Next Up names once the player exits, which is the NEXT episode as soon as the
/// watched one passed the server's played threshold. That is the whole "only after a long watch" part
/// of the report.
@MainActor
struct PrefetchedPlaybackInfoIdentityTests {
    struct NotUsed: Error {}

    private static func item(_ id: String, type: String = "Episode") throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"}"#.utf8)
        )
    }

    private static func playbackInfo(sourceID: String) throws -> PlaybackInfoResponse {
        try JSONDecoder().decode(
            PlaybackInfoResponse.self,
            from: Data(
                #"{"MediaSources":[{"Id":"\#(sourceID)","Container":"mkv","SupportsDirectPlay":true}],"PlaySessionId":"ps"}"#.utf8
            )
        )
    }

    private static func response(_ items: [JellyfinItem]) -> JellyfinItemsResponse {
        JellyfinItemsResponse(items: items, totalRecordCount: items.count)
    }

    /// Answers PlaybackInfo with a source whose id equals the requested item id, which is what Jellyfin
    /// does for an ordinary single-version item.
    final class MockPlaybackService: JellyfinPlaybackServiceProtocol, @unchecked Sendable {
        var baseURL: URL? { URL(string: "http://server") }
        var deviceID: String { "device" }
        private(set) var requestedItemIDs: [String] = []

        func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse {
            requestedItemIDs.append(itemID)
            return try JSONDecoder().decode(
                PlaybackInfoResponse.self,
                from: Data(
                    #"{"MediaSources":[{"Id":"\#(itemID)","Container":"mkv","SupportsDirectPlay":true}],"PlaySessionId":"ps"}"#.utf8
                )
            )
        }

        func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]?, maxStreamingBitrate: Int, enableDirectPlay: Bool) async throws -> PlaybackInfoResponse {
            throw NotUsed()
        }
        func reportPlaybackStart(_ report: PlaybackStartReport) async throws {}
        func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws {}
        func reportPlaybackStopped(_ report: PlaybackStopReport) async throws {}
        func closeLiveStream(liveStreamID: String) async throws {}
        func stopActiveEncodings(playSessionID: String) async throws {}
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

    /// Next Up answers with whatever the test staged, standing in for the server rolling forward once
    /// the watched episode crosses the played threshold.
    final class MockLibraryService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var nextUp: JellyfinItemsResponse

        init(nextUp: JellyfinItemsResponse) {
            self.nextUp = nextUp
        }

        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            nextUp
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    /// Every member throws: the scenarios below never load detail, and `refreshResumePosition` treats a
    /// failed episode fetch as "nothing to reconcile", which keeps the Next Up branch isolated.
    final class MockItemService: JellyfinItemServiceProtocol, @unchecked Sendable {
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw NotUsed() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(
            userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?
        ) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {}
    }

    private func makeViewModel(
        playback: MockPlaybackService,
        library: MockLibraryService
    ) throws -> DetailViewModel {
        DetailViewModel(
            item: try Self.item("series1", type: "Series"),
            itemService: MockItemService(),
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            libraryService: library,
            playbackService: playback
        )
    }

    /// The prefetch is fire-and-forget; yield until it lands rather than sleeping.
    private func awaitPrefetch(_ vm: DetailViewModel) async {
        for _ in 0..<100 where vm.cachedPlaybackInfo == nil {
            await Task.yield()
        }
    }

    @Test func aPrefetchNamesTheItemItWasFetchedFor() async throws {
        let playback = MockPlaybackService()
        let vm = try makeViewModel(playback: playback, library: MockLibraryService(nextUp: Self.response([])))

        vm.prefetchPlaybackInfo(for: "e5")
        await awaitPrefetch(vm)

        #expect(vm.cachedPlaybackInfo?.matching("e5", quality: .original)?.mediaSources.first?.id == "e5")
        #expect(vm.cachedPlaybackInfo?.matching("e6", quality: .original) == nil)
    }

    /// The reported failure: watched past the played threshold, so leaving the player rolls Next Up to
    /// the following episode while the prefetched response still describes the one just watched.
    @Test func nextUpRollingForwardDoesNotHandTheWatchedEpisodesSourceToTheNextOne() async throws {
        let playback = MockPlaybackService()
        let library = MockLibraryService(nextUp: Self.response([]))
        let vm = try makeViewModel(playback: playback, library: library)

        vm.prefetchPlaybackInfo(for: "e5")
        await awaitPrefetch(vm)
        vm.currentEpisodeID = "e5"

        library.nextUp = Self.response([try Self.item("e6")])
        await vm.refreshResumePosition()

        #expect(vm.currentEpisodeID == "e6")
        // What the launcher hands the player for the play target it now shows.
        #expect(vm.cachedPlaybackInfo?.matching("e6", quality: .original) == nil)
    }

    /// The other half of the same rule: a replaced item is a new file, so the response prefetched for
    /// the id that died describes neither the corpse nor its successor.
    @Test func anItemReplacementDropsThePrefetchItNamed() async throws {
        let playback = MockPlaybackService()
        let vm = try makeViewModel(playback: playback, library: MockLibraryService(nextUp: Self.response([])))

        vm.prefetchPlaybackInfo(for: "e5")
        await awaitPrefetch(vm)

        vm.applyItemReplacement(staleID: "e5", newItem: try Self.item("e5new"))

        #expect(vm.cachedPlaybackInfo == nil)
    }

    /// A prefetch in flight for a new target must not leave the previous target's response readable:
    /// the play button can fire in that window.
    @Test func aNewPrefetchDropsThePreviousResponseImmediately() async throws {
        let playback = MockPlaybackService()
        let vm = try makeViewModel(playback: playback, library: MockLibraryService(nextUp: Self.response([])))

        vm.prefetchPlaybackInfo(for: "e5")
        await awaitPrefetch(vm)
        #expect(vm.cachedPlaybackInfo?.matching("e5", quality: .original) != nil)

        vm.prefetchPlaybackInfo(for: "e6")
        #expect(vm.cachedPlaybackInfo == nil)
    }
}

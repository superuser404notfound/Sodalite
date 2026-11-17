import Testing
import Foundation
@testable import Sodalite

/// Audit DET-202, 203, 204, 205, 206, 207: what a detail page shows for watched, resume position and
/// favourite after the viewer's own writes, playback stops and slow responses.
@MainActor
struct DetailViewModelUserStateTests {
    struct Failure: Error {}

    /// A gate a fake service parks on until the test lets it go.
    final class Gate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private(set) var reached = false
        init() { (stream, continuation) = AsyncStream.makeStream() }
        func wait() async {
            reached = true
            for await _ in stream { return }
        }
        func open() { continuation.yield() }
        func waitUntilReached() async { while !reached { await Task.yield() } }
    }

    final class Service: JellyfinItemServiceProtocol, @unchecked Sendable {
        var detail: JellyfinItem?
        var detailGate: Gate?
        var seasons: [JellyfinItem] = []
        var episodes: [String: [JellyfinItem]] = [:]
        var episodesGate: Gate?

        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
            await detailGate?.wait()
            guard let detail else { throw Failure() }
            return detail
        }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: seasons, totalRecordCount: seasons.count)
        }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
            await episodesGate?.wait()
            let items = episodes[seasonID] ?? []
            return JellyfinItemsResponse(items: items, totalRecordCount: items.count)
        }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw Failure() }
        func getPlaylistItems(playlistID: String, userID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse { throw Failure() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func setRating(userID: String, itemID: String, rating: Double?) async throws {}
        func clearPlaybackPosition(userID: String, itemID: String) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Failure() }
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(
            userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?
        ) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {}
    }

    final class Library: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var nextUp: JellyfinItem?
        var nextUpGate: Gate?
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            await nextUpGate?.wait()
            let items = nextUp.map { [$0] } ?? []
            return JellyfinItemsResponse(items: items, totalRecordCount: items.count)
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Failure() }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { throw Failure() }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func decode(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func episode(_ id: String, season: String, position: Int64? = nil) throws -> JellyfinItem {
        let user = position.map { #","UserData":{"PlaybackPositionTicks":\#($0)}"# } ?? ""
        return try decode(
            #"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeasonId":"\#(season)","RunTimeTicks":1000\#(user)}"#)
    }

    private func season(_ id: String) throws -> JellyfinItem {
        try decode(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Season"}"#)
    }

    private func makeVM(
        _ json: String, service: Service = Service(), library: Library? = nil
    ) throws -> DetailViewModel {
        DetailViewModel(
            item: try decode(json),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            libraryService: library
        )
    }

    private let seriesJSON = #"{"Id":"series1","Name":"Show","Type":"Series"}"#

    // MARK: DET-205

    @Test func markingWatchedDropsTheResumePositionFromTheEffectiveState() async throws {
        let vm = try makeVM(seriesJSON)
        let ep = try episode("e1", season: "s1", position: 400)
        #expect(vm.effectiveState(of: ep).positionTicks == 400)

        await vm.setEpisodePlayed(ep, isPlayed: true)

        let state = vm.effectiveState(of: ep)
        #expect(state.positionTicks == 0)
        #expect(PlayActionState.resolve(positionTicks: state.positionTicks, isPlayed: state.isPlayed) == .again)
        #expect(vm.resolvedForPlayback(ep).userData?.playbackPositionTicks == 0)
    }

    // MARK: DET-206

    @Test func aFinishingPlaybackRetiresTheUnwatchedMark() async throws {
        let vm = try makeVM(seriesJSON)
        let ep = try episode("e1", season: "s1")
        vm.episodes = [ep]
        await vm.setEpisodePlayed(ep, isPlayed: false)
        #expect(!vm.isPlayed(ep))

        vm.applyPlaybackPosition(itemID: "e1", ticks: 990)

        #expect(vm.isPlayed(vm.episodes[0]))
    }

    @Test func aPartialReWatchKeepsItsResumeStateAfterAWatchedMark() async throws {
        let vm = try makeVM(seriesJSON)
        let ep = try episode("e1", season: "s1")
        vm.episodes = [ep]
        await vm.setEpisodePlayed(ep, isPlayed: true)
        #expect(vm.wasMarkedPlayedInSession(ep))

        vm.applyPlaybackPosition(itemID: "e1", ticks: 300)

        #expect(!vm.wasMarkedPlayedInSession(vm.episodes[0]))
        #expect(vm.effectiveState(of: vm.episodes[0]).positionTicks == 300)
    }

    // MARK: DET-202

    @Test func aCollectionPageFollowsAFinishedFilm() async throws {
        let vm = try makeVM(#"{"Id":"box1","Name":"Box","Type":"BoxSet"}"#)
        let film1 = try decode(#"{"Id":"f1","Name":"One","Type":"Movie","RunTimeTicks":1000}"#)
        let film2 = try decode(#"{"Id":"f2","Name":"Two","Type":"Movie","RunTimeTicks":1000}"#)
        vm.collectionItems = [film1, film2]
        func start() -> Int {
            CollectionPlaybackQueue.startIndex(playedFlags: vm.collectionItems.map { vm.isPlayed($0) })
        }
        #expect(start() == 0)

        await vm.handlePlaybackStop(itemID: "f1", ticks: 990)

        #expect(start() == 1)
    }

    @Test func aReplacedFilmIsSwappedInTheCollection() throws {
        let vm = try makeVM(#"{"Id":"box1","Name":"Box","Type":"BoxSet"}"#)
        vm.collectionItems = [try decode(#"{"Id":"old","Name":"One","Type":"Movie"}"#)]
        vm.applyItemReplacement(staleID: "old", newItem: try decode(#"{"Id":"new","Name":"One","Type":"Movie"}"#))
        #expect(vm.collectionItems.map(\.id) == ["new"])
    }

    // MARK: DET-207

    @Test func aDetailResponseThatStartedBeforeAFavouriteToggleDoesNotUndoIt() async throws {
        let service = Service()
        let gate = Gate()
        service.detailGate = gate
        service.detail = try decode(#"{"Id":"m1","Name":"Film","Type":"Movie"}"#)
        let vm = try makeVM(#"{"Id":"m1","Name":"Film","Type":"Movie"}"#, service: service)

        let load = Task { await vm.loadFullDetail() }
        await gate.waitUntilReached()
        await vm.toggleFavorite()
        #expect(vm.isFavorite)
        gate.open()
        await load.value

        #expect(vm.isFavorite)
    }

    @Test func aFailedSeasonMarkRollsBackOnlyItsOwnKeys() async throws {
        final class Failing: JellyfinItemServiceProtocol, @unchecked Sendable {
            let base = Service()
            func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws { throw Failure() }
            func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw Failure() }
            func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
            func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
            func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw Failure() }
            func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw Failure() }
            func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw Failure() }
            func getPlaylistItems(playlistID: String, userID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse { throw Failure() }
            func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
            func setRating(userID: String, itemID: String, rating: Double?) async throws {}
            func clearPlaybackPosition(userID: String, itemID: String) async throws {}
            func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Failure() }
            func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
            func findByProviderIDs(userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?) async throws -> JellyfinItem? { nil }
            func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
            func deleteItem(itemID: String) async throws {}
        }
        let vm = DetailViewModel(
            item: try decode(seriesJSON), itemService: Failing(),
            imageService: JellyfinImageService(baseURLProvider: { nil }), userID: "u1")
        vm.playedOverrides["other"] = true

        await vm.setSeasonPlayed(seasonID: "s1", isPlayed: true)

        #expect(vm.playedOverrides["other"] == true)
        #expect(vm.playedOverrides["s1"] == nil)
    }

    // MARK: DET-203, DET-204

    @Test func aLateResumeRefreshDoesNotOverwriteTheSeasonThePickedSince() async throws {
        let service = Service()
        let gate = Gate()
        service.episodesGate = gate
        service.episodes["s2"] = [try episode("s2e1", season: "s2")]
        let vm = try makeVM(seriesJSON, service: service)
        vm.selectedSeasonID = "s2"

        let refresh = Task { await vm.refreshResumePosition() }
        await gate.waitUntilReached()
        vm.selectedSeasonID = "s3"
        vm.episodes = [try episode("s3e1", season: "s3")]
        gate.open()
        await refresh.value

        #expect(vm.episodes.map(\.id) == ["s3e1"])
    }

    @Test func aLateNextUpAnswerKeepsTheSeasonTheViewerPicked() async throws {
        let service = Service()
        service.seasons = [try season("s1"), try season("s2"), try season("s4")]
        service.episodes["s4"] = [try episode("s4e1", season: "s4")]
        let library = Library()
        let gate = Gate()
        library.nextUpGate = gate
        library.nextUp = try episode("s2e3", season: "s2")
        let vm = try makeVM(seriesJSON, service: service, library: library)

        let load = Task { await vm.loadSeasons() }
        await gate.waitUntilReached()
        await vm.loadEpisodes(seasonID: "s4")
        gate.open()
        await load.value

        #expect(vm.selectedSeasonID == "s4")
        #expect(vm.nextUpEpisode?.id == "s2e3")
    }
}

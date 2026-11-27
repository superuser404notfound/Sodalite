import Foundation
import Testing
@testable import Sodalite

/// Show All on every capped Home row (Sodalite#258): which rows know there is more, and which grid
/// the card opens.
@MainActor
struct HomeShowAllTests {
    final class FakeLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var latest: [JellyfinItem] = []
        var page: [JellyfinItem] = []
        var total: Int?
        var resume: [JellyfinItem] = []

        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            Array(latest.prefix(limit))
        }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            let items = Array(page.prefix(query.limit ?? page.count))
            return .init(items: items, totalRecordCount: total ?? items.count)
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            .init(items: resume, totalRecordCount: resume.count + 40)
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    private func movie(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"Film \#(id)","Type":"Movie"}"#.utf8))
    }

    private func movies(_ count: Int) throws -> [JellyfinItem] {
        try (0..<count).map { try movie("m\($0)") }
    }

    private func model(_ library: FakeLibrary) -> HomeViewModel {
        HomeViewModel(
            libraryService: library,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u", serverID: "srv-\(UUID().uuidString)")
    }

    private func load(_ type: HomeRowType, _ library: FakeLibrary, libraryID: String? = nil, collectionType: String? = nil) async throws -> HomeRowData? {
        let vm = model(library)
        let config = HomeRowConfig(
            type: type, isEnabled: true, sortOrder: 0,
            libraryID: libraryID, libraryName: libraryID.map { _ in "Popular" }, collectionType: collectionType
        )
        return try await vm.loadRow(config: config, source: vm.sources[0])
    }

    // MARK: - Which rows know there is more

    @Test func aFullPageLeavesMore() async throws {
        let library = FakeLibrary()
        library.page = try movies(45)
        let row = try await load(.favorites, library)
        #expect(row?.items.count == 30)
        #expect(row?.hasMore == true)
    }

    @Test func aShortPageIsTheWholeList() async throws {
        let library = FakeLibrary()
        library.page = try movies(12)
        let row = try await load(.topRatedMovies, library)
        #expect(row?.hasMore == false)
    }

    /// A server that builds its lists from remote catalogs reports a total that ends at the page it
    /// sent, so the total alone would say there is nothing more.
    @Test func aTotalEndingAtThePageStillLeavesMore() async throws {
        let library = FakeLibrary()
        library.page = try movies(20)
        library.total = 20
        let row = try await load(.recentlyAdded, library)
        #expect(row?.hasMore == true)
    }

    @Test func aTotalPastAShortPageLeavesMore() async throws {
        let library = FakeLibrary()
        library.page = try movies(8)
        library.total = 90
        let row = try await load(.favorites, library)
        #expect(row?.hasMore == true)
    }

    @Test func aCatalogRowWithAFullLatestLeavesMore() async throws {
        let library = FakeLibrary()
        library.latest = try movies(40)
        let row = try await load(.libraryLatest, library, libraryID: "lib", collectionType: "movies")
        #expect(row?.items.count == 16)
        #expect(row?.hasMore == true)
    }

    @Test func aSmallLibraryHasNoShowAll() async throws {
        let library = FakeLibrary()
        library.latest = try movies(5)
        let row = try await load(.libraryLatest, library, libraryID: "lib", collectionType: "movies")
        #expect(row?.hasMore == false)
    }

    @Test func continueWatchingNeverOffersMore() async throws {
        let library = FakeLibrary()
        library.resume = try movies(16)
        let row = try await load(.continueWatching, library)
        #expect(row?.items.count == 16)
        #expect(row?.hasMore == false)
    }

    @Test func aCachedRowFromBeforeTheFlagDecodesWithout() throws {
        let json = #"{"type":"favorites","items":[]}"#
        let row = try JSONDecoder().decode(HomeRowData.self, from: Data(json.utf8))
        #expect(row.hasMore == false)
    }

    // MARK: - Combined servers

    @Test func aMergedRowLeavesMoreWhenOneServerDid() throws {
        let a = HomeRowData(type: .favorites, items: try movies(3), hasMore: true)
        let b = HomeRowData(type: .favorites, items: [try movie("b")])
        #expect(HomeMerger.leavesMore([a, b], shown: 4, type: .favorites, mergedContinueWatching: false))
    }

    @Test func aMergedRowLeavesMoreWhenTheMergeCutIt() throws {
        let a = HomeRowData(type: .latestMovies, items: try (0..<10).map { try movie("a\($0)") })
        let b = HomeRowData(type: .latestMovies, items: try (0..<10).map { try movie("b\($0)") })
        #expect(HomeMerger.leavesMore([a, b], shown: 16, type: .latestMovies, mergedContinueWatching: false))
        #expect(!HomeMerger.leavesMore([a, b], shown: 20, type: .latestMovies, mergedContinueWatching: false))
    }

    // MARK: - The grid behind the card

    private func row(_ type: HomeRowType, hasMore: Bool = true, libraryID: String? = nil, collectionType: String? = nil) -> HomeRowData {
        HomeRowData(type: type, items: [], libraryID: libraryID, libraryName: "Popular", collectionType: collectionType, hasMore: hasMore)
    }

    @Test func aRowWithNothingBehindItHasNoGrid() {
        #expect(HomeShowAll.grid(for: row(.latestMovies, hasMore: false)) == nil)
    }

    @Test func queuesHaveNoGrid() {
        for type in [HomeRowType.continueWatching, .nextUp, .upcoming] {
            #expect(HomeShowAll.grid(for: row(type)) == nil, "\(type)")
        }
    }

    @Test func latestRowsKeepTheirOrderWithoutAPicker() throws {
        let movies = try #require(HomeShowAll.grid(for: row(.latestMovies)))
        #expect(movies.query.includeItemTypes == [.movie])
        #expect(movies.defaultSort == .newestAdded)
        #expect(!movies.offersSort)

        let shows = try #require(HomeShowAll.grid(for: row(.latestShows)))
        #expect(shows.query.includeItemTypes == [.series])
        #expect(shows.defaultSort == .newestEpisode)
        #expect(shows.defaultSort.applied(to: shows.query).sortBy == "DateLastContentAdded,SortName")
        // A combined grid merges servers by the date, so it has to be on the cards.
        #expect(shows.query.fields.contains("DateLastMediaAdded"))
    }

    @Test func releaseAndRatingRowsOpenInTheirOrder() throws {
        let released = try #require(HomeShowAll.grid(for: row(.recentlyReleasedMovies)))
        #expect(released.defaultSort == .newestReleased)
        #expect(released.query.maxPremiereDate != nil)

        let episodes = try #require(HomeShowAll.grid(for: row(.recentlyReleasedShows)))
        #expect(episodes.query.includeItemTypes == [.episode])
        #expect(episodes.query.isMissing == false)

        let rated = try #require(HomeShowAll.grid(for: row(.topRatedShows)))
        #expect(rated.query.includeItemTypes == [.series])
        #expect(rated.defaultSort == .highestRated)
    }

    @Test func listRowsOfferThePicker() throws {
        let favorites = try #require(HomeShowAll.grid(for: row(.favorites)))
        #expect(favorites.query.isFavorite == true)
        #expect(favorites.defaultSort == .default)
        #expect(favorites.offersSort)

        let playlists = try #require(HomeShowAll.grid(for: row(.playlists)))
        #expect(playlists.hidesAudioPlaylists)
        #expect(playlists.offersSort)
    }

    @Test func favoriteEpisodesStayInShowOrder() throws {
        let grid = try #require(HomeShowAll.grid(for: row(.favoriteEpisodes)))
        #expect(grid.query.includeItemTypes == [.episode])
        #expect(grid.query.isFavorite == true)
        #expect(grid.defaultSort.applied(to: grid.query).sortBy == "SeriesSortName,ParentIndexNumber,IndexNumber,SortName")
        #expect(grid.defaultSort.applied(to: grid.query).sortOrder == "Ascending")
    }

    @Test func aCatalogRowOpensItsLibraryNewestFirst() throws {
        let movies = try #require(HomeShowAll.grid(for: row(.libraryLatest, libraryID: "lib", collectionType: "movies")))
        #expect(movies.query.parentID == "lib")
        #expect(movies.query.includeItemTypes == [.movie])
        #expect(movies.query.collapseBoxSetItems == false)
        #expect(movies.defaultSort == .newestAdded)

        let shows = try #require(HomeShowAll.grid(for: row(.libraryLatest, libraryID: "tv", collectionType: "tvshows")))
        #expect(shows.query.includeItemTypes == [.series])
        #expect(shows.defaultSort == .newestEpisode)

        let mixed = try #require(HomeShowAll.grid(for: row(.libraryLatest, libraryID: "mix", collectionType: nil)))
        #expect(mixed.query.includeItemTypes == [.movie, .series])
    }

    /// Collection shelves, All Movies and All Series open grids of their own in HomeView.
    @Test func rowsWithTheirOwnGridAreLeftAlone() {
        #expect(HomeShowAll.grid(for: row(.libraryLatest, libraryID: "box", collectionType: "boxsets")) == nil)
        #expect(HomeShowAll.grid(for: row(.allMovies)) == nil)
        #expect(HomeShowAll.grid(for: row(.allSeries)) == nil)
    }

    @Test func theGridTitleIsTheRowTitle() {
        #expect(HomeShowAll.title(for: row(.libraryLatest, libraryID: "lib")).contains("Popular"))
        #expect(HomeShowAll.title(for: row(.favorites)) == String(localized: "home.favorites"))
    }
}

import Foundation
import Testing
@testable import Sodalite

/// The library grid's filter menu (Sodalite#252): how a choice becomes a query on each server.
@MainActor
struct LibraryFilterTests {
    private func value(_ name: String, in query: ItemQuery) -> String? {
        query.toQueryItems().first { $0.name == name }?.value
    }

    private var movies: ItemQuery {
        ItemQuery(parentID: "lib", includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields)
    }

    private var serverFacets: ServerFacets {
        ServerFacets(
            genres: ["Action", "Horror"],
            genreIDs: ["action": "g-action", "horror": "g-horror"],
            studios: ["A24"],
            studioIDs: ["a24": "s-a24"]
        )
    }

    // MARK: - Query mapping

    @Test func emptySelectionLeavesTheQueryAlone() throws {
        let narrowed = try #require(LibraryFilterSelection().applied(to: movies, facets: nil))
        #expect(narrowed.toQueryItems() == movies.toQueryItems())
    }

    @Test func menuFiltersJoinTheWatchChoice() throws {
        var query = movies
        query.filters = ["IsUnplayed"]
        var selection = LibraryFilterSelection()
        selection.states = [.favorites, .continueWatching]
        let narrowed = try #require(selection.applied(to: query, facets: nil))
        #expect(value("Filters", in: narrowed) == "IsUnplayed,IsFavorite,IsResumable")
    }

    @Test func eachGroupGoesOutUnderItsOwnParameterAndDelimiter() throws {
        var selection = LibraryFilterSelection()
        selection.features = [.subtitles, .themeSongs]
        selection.videoTypes = [.uhd, .threeD, .iso, .dvd]
        selection.officialRatings = ["FSK-6", "FSK-0"]
        selection.tags = ["noir", "1980s"]
        selection.years = [1999, 1995]
        selection.audioLanguages = ["jpn", "deu"]
        selection.subtitleLanguages = ["eng"]
        selection.seriesStatus = [.ended, .continuing]
        let narrowed = try #require(selection.applied(to: movies, facets: nil))
        #expect(value("HasSubtitles", in: narrowed) == "true")
        #expect(value("HasThemeSong", in: narrowed) == "true")
        #expect(value("HasTrailer", in: narrowed) == nil)
        #expect(value("Is4K", in: narrowed) == "true")
        #expect(value("Is3D", in: narrowed) == "true")
        #expect(value("IsHd", in: narrowed) == nil)
        #expect(value("VideoTypes", in: narrowed) == "Dvd,Iso")
        #expect(value("OfficialRatings", in: narrowed) == "FSK-0|FSK-6")
        #expect(value("Tags", in: narrowed) == "1980s|noir")
        #expect(value("Years", in: narrowed) == "1995,1999")
        #expect(value("AudioLanguages", in: narrowed) == "deu,jpn")
        #expect(value("SubtitleLanguages", in: narrowed) == "eng")
        #expect(value("SeriesStatus", in: narrowed) == "Continuing,Ended")
    }

    @Test func sdAndHdAreTheTwoValuesOfIsHd() throws {
        var selection = LibraryFilterSelection()
        selection.toggle(.sd)
        #expect(value("IsHd", in: try #require(selection.applied(to: movies, facets: nil))) == "false")
        selection.toggle(.hd)
        #expect(value("IsHd", in: try #require(selection.applied(to: movies, facets: nil))) == "true")
    }

    /// SD and HD share `IsHd`, so one replaces the other. `Is4K` is its own parameter, which the
    /// server ORs with `IsHd` (12.2: HD 9 movies, 4K 50, both 59), so 4K stays next to either.
    @Test func sdAndHdReplaceEachOtherAnd4KCombines() throws {
        var selection = LibraryFilterSelection()
        selection.toggle(.sd)
        selection.toggle(.threeD)
        selection.toggle(.uhd)
        #expect(selection.videoTypes == [.sd, .uhd, .threeD])
        selection.toggle(.hd)
        #expect(selection.videoTypes == [.hd, .uhd, .threeD])
        let narrowed = try #require(selection.applied(to: movies, facets: nil))
        #expect(value("IsHd", in: narrowed) == "true")
        #expect(value("Is4K", in: narrowed) == "true")
        selection.toggle(.uhd)
        #expect(selection.videoTypes == [.hd, .threeD])
    }

    // MARK: - Genres and studios by id, per server

    @Test func genresAndStudiosGoOutAsThisServersIds() throws {
        var selection = LibraryFilterSelection()
        selection.genres = ["Horror", "Action"]
        selection.studios = ["a24"]
        let narrowed = try #require(selection.applied(to: movies, facets: serverFacets))
        #expect(value("GenreIds", in: narrowed) == "g-action|g-horror")
        #expect(value("Genres", in: narrowed) == nil)
        #expect(value("StudioIds", in: narrowed) == "s-a24")
        #expect(value("Studios", in: narrowed) == nil)
    }

    /// Measured on Jellyfin 12.2: `Genres` and `GenreIds` are separate constraints, so a genre
    /// tile's own genre and the menu's narrow together.
    @Test func aGenreTileKeepsItsGenreAndAddsTheMenusById() throws {
        var tile = movies
        tile.genres = ["Horror"]
        var selection = LibraryFilterSelection()
        selection.genres = ["Action"]
        let narrowed = try #require(selection.applied(to: tile, facets: serverFacets))
        #expect(value("Genres", in: narrowed) == "Horror")
        #expect(value("GenreIds", in: narrowed) == "g-action")
    }

    /// Leaving the parameter off would widen the grid to everything.
    @Test func aServerWithoutAnyPickedGenreCannotMatch() {
        var selection = LibraryFilterSelection()
        selection.genres = ["Western"]
        #expect(selection.applied(to: movies, facets: serverFacets) == nil)
    }

    @Test func aServerThatDidNotAnswerFallsBackToNames() throws {
        var selection = LibraryFilterSelection()
        selection.genres = ["Horror"]
        selection.studios = ["A24"]
        let narrowed = try #require(selection.applied(to: movies, facets: nil))
        #expect(value("Genres", in: narrowed) == "Horror")
        #expect(value("Studios", in: narrowed) == "A24")
    }

    /// Names would OR with the tile's genre instead of narrowing it.
    @Test func aGenreTileWithoutIdsCannotNarrowByGenre() {
        var tile = movies
        tile.genres = ["Horror"]
        var selection = LibraryFilterSelection()
        selection.genres = ["Action"]
        #expect(selection.applied(to: tile, facets: nil) == nil)
    }

    // MARK: - Endpoint

    /// `/Users/{id}/Items` ignores the language parameters (Jellyfin 12.2), `/Items` honours them.
    @Test func languageFiltersMoveTheQueryToItemsWithUserId() {
        var query = movies
        #expect(JellyfinEndpoint.items(userID: "u", query: query).path == "/Users/u/Items")
        query.subtitleLanguages = ["eng"]
        let endpoint = JellyfinEndpoint.items(userID: "u", query: query)
        #expect(endpoint.path == "/Items")
        #expect(endpoint.queryItems?.first { $0.name == "UserId" }?.value == "u")
    }

    @Test func facetCallsAskForTheGridsOwnLibrary() {
        let scope = FacetScope(parentID: "lib", includeItemTypes: [.movie, .series], recursive: false)
        let filters2 = JellyfinEndpoint.itemFilters2(userID: "u", scope: scope)
        #expect(filters2.path == "/Items/Filters2")
        let items = filters2.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "ParentId", value: "lib")))
        #expect(items.contains(URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")))
        #expect(items.contains(URLQueryItem(name: "Recursive", value: "false")))
        let studios = JellyfinEndpoint.studios(userID: "u", scope: scope).queryItems ?? []
        #expect(!studios.contains { $0.name == "Recursive" })
    }

    // MARK: - Facets and groups

    @Test func facetsFromSeveralServersJoinCaseInsensitively() {
        var a = ServerFacets()
        a.genres = ["horror", "Drama"]
        a.years = [1999, 2001]
        a.audioLanguages = [LanguageFacet(name: "German (deu)", value: "deu")]
        var b = ServerFacets()
        b.genres = ["Action", "Horror"]
        b.years = [2001, 2024]
        b.audioLanguages = [LanguageFacet(name: "German", value: "DEU"), LanguageFacet(name: "English (eng)", value: "eng")]
        let merged = LibraryFacets.merge([("a", a), ("b", b)])
        #expect(merged.genres == ["Action", "Drama", "horror"])
        #expect(merged.years == [2024, 2001, 1999])
        #expect(merged.audioLanguages.map(\.value) == ["eng", "deu"])
        #expect(merged.byServer.keys.sorted() == ["a", "b"])
    }

    /// One server sends tags and studios in no useful order, which made a long list unusable.
    @Test func facetsFromOneServerAreSortedToo() {
        var a = ServerFacets()
        a.tags = ["noir", "Heist", "1980s", "ambient"]
        a.studios = ["Warner Bros.", "A24"]
        let merged = LibraryFacets.merge([("a", a)])
        #expect(merged.tags == ["1980s", "ambient", "Heist", "noir"])
        #expect(merged.studios == ["A24", "Warner Bros."])
    }

    @Test func searchNarrowsCaseAndAccentBlind() {
        let options = ["Amélie Studios", "neo-noir", "Noir", "Heist"].map { title in
            LibraryFilterSheet.Option(id: title, title: title, isOn: { _ in false }, toggle: { _ in })
        }
        #expect(LibraryFilterSheet.narrowed(options, by: "amelie").map(\.title) == ["Amélie Studios"])
        #expect(LibraryFilterSheet.narrowed(options, by: " NOIR ").map(\.title) == ["neo-noir", "Noir"])
        #expect(LibraryFilterSheet.narrowed(options, by: "").count == 4)
    }

    @Test func groupsTheServerAnsweredEmptyStayHidden() {
        var facets = LibraryFacets()
        facets.genres = ["Drama"]
        facets.byServer["s"] = ServerFacets(genres: ["Drama"], genreIDs: ["drama": "g"])
        let groups = LibraryFilterGroups.visible(for: movies, facets: facets)
        #expect(groups == [.filters, .features, .videoType, .genres])
        #expect(LibraryFilterGroups.visible(for: movies, facets: nil) == [.filters, .features, .videoType])
    }

    @Test func seriesStatusOnlyWhereTheGridHoldsSeries() {
        var shows = movies
        shows.includeItemTypes = [.series]
        #expect(LibraryFilterGroups.visible(for: shows, facets: nil).contains(.seriesStatus))
        #expect(!LibraryFilterGroups.visible(for: movies, facets: nil).contains(.seriesStatus))
    }

    /// Resolution and disc type describe files; a shows grid lists series rows.
    @Test func videoTypeIsHiddenOnAShowsGrid() {
        var shows = movies
        shows.includeItemTypes = [.series]
        #expect(!LibraryFilterGroups.visible(for: shows, facets: nil).contains(.videoType))
        var mixed = movies
        mixed.includeItemTypes = [.movie, .series]
        #expect(LibraryFilterGroups.visible(for: mixed, facets: nil).contains(.videoType))
        mixed.includeItemTypes = nil
        #expect(LibraryFilterGroups.visible(for: mixed, facets: nil).contains(.videoType))
    }

    /// The server takes a studio tile's `Studios` names and drops `StudioIds`.
    @Test func aStudioTileHidesTheStudioGroup() {
        var tile = movies
        tile.studioNames = ["Netflix"]
        var facets = LibraryFacets()
        facets.studios = ["A24"]
        #expect(!LibraryFilterGroups.visible(for: tile, facets: facets).contains(.studios))
        #expect(LibraryFilterGroups.visible(for: movies, facets: facets).contains(.studios))
    }

    // MARK: - Grids that ask several servers

    @Test func aServerThatCannotMatchDropsOutOfTheCombinedPager() {
        let library = CombinedGridTests.GridLibrary()
        let sources = [
            HomeSource(serverID: "a", serverName: "A", userID: "u", libraryService: library, isActive: true),
            HomeSource(serverID: "b", serverName: "B", userID: "u", libraryService: library, isActive: false),
        ]
        let pager = MergedPager.sources(from: sources) { $0.serverID == "b" ? nil : ItemQuery(fields: "") }
        #expect(pager.map(\.serverID) == ["a"])
    }

    @Test func theMenuJoinsThePhase2CacheKey() {
        var horror = LibraryFilterSelection()
        horror.genres = ["Horror"]
        let cached = FilteredGridView.Phase2Filter(watch: .all, menu: LibraryFilterSelection())
        #expect(!FilteredGridView.canReuseCachedPhase2(
            smartProviderID: 8, cacheFilter: cached,
            currentFilter: FilteredGridView.Phase2Filter(watch: .all, menu: horror)))
        #expect(FilteredGridView.canReuseCachedPhase2(
            smartProviderID: 8, cacheFilter: cached,
            currentFilter: FilteredGridView.Phase2Filter(watch: .all, menu: LibraryFilterSelection())))
    }

    // MARK: - Shuffle

    final class ShuffleLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var queries: [ItemQuery] = []
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            queries.append(query)
            if query.includeItemTypes == [.series] {
                let shows = try ["s1", "s2"].map { id in
                    try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"\#(id)","Name":"x","Type":"Series"}"#.utf8))
                }
                return JellyfinItemsResponse(items: shows, totalRecordCount: 2)
            }
            let episode = try JSONDecoder().decode(
                JellyfinItem.self, from: Data(#"{"Id":"e-\#(query.parentID ?? "")","Name":"x","Type":"Episode"}"#.utf8))
            return JellyfinItemsResponse(items: [episode], totalRecordCount: 1)
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    /// Series filters do not carry onto episodes, so a filtered shows shuffle picks series first.
    @Test func aFilteredShowsShuffleDrawsEpisodesFromTheMatchingSeries() async throws {
        let library = ShuffleLibrary()
        var shows = movies
        shows.includeItemTypes = [.series]
        shows.filters = ["IsUnplayed", "IsFavorite"]
        shows.genreIDs = ["g-anim"]
        let queue = await VideoShuffleQueue.buildFromSeries(seriesQuery: shows, service: library, userID: "u")
        #expect(Set(queue.map(\.id)) == ["e-s1", "e-s2"])
        let seriesQuery = try #require(library.queries.first { $0.includeItemTypes == [.series] })
        #expect(seriesQuery.genreIDs == ["g-anim"])
        // Shuffle ignores the watch choice (Sodalite#17) and keeps the menu's favorites.
        #expect(seriesQuery.filters == ["IsFavorite"])
        let episodeQueries = library.queries.filter { $0.includeItemTypes == [.episode] }
        #expect(Set(episodeQueries.compactMap(\.parentID)) == ["s1", "s2"])
        #expect(episodeQueries.allSatisfy { $0.genreIDs == nil })
    }
}

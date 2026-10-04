import Foundation
import Testing
@testable import Sodalite

/// Findings from the Phase 3 branch review (Sodalite#85).
@MainActor
struct CombinedGridReviewFixTests {
    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    private func item(_ id: String, server: String, sort: String, rating: Double? = nil, tmdb: String? = nil) throws -> JellyfinItem {
        var extra = ""
        if let rating { extra += #","CommunityRating":\#(rating)"# }
        if let tmdb { extra += #","ProviderIds":{"Tmdb":"\#(tmdb)"}"# }
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(sort)","SortName":"\#(sort)","Type":"Movie","ServerId":"\#(server)"\#(extra)}"#.utf8))
    }

    private func source(_ server: String, _ all: [JellyfinItem], active: Bool = false, fail: Bool = false) -> MergedPager.Source {
        MergedPager.Source(serverID: server, isActive: active) { start, limit in
            if fail { throw URLError(.notConnectedToInternet) }
            return JellyfinItemsResponse(items: Array(all.dropFirst(start).prefix(limit)), totalRecordCount: all.count)
        }
    }

    // MARK: I1

    /// SQLite, under Jellyfin, sorts NULL as the smallest value: first ascending, last descending.
    @Test func missingKeysSortAsTheSmallestValue() throws {
        let rated = try item("r", server: "a", sort: "b", rating: 7)
        let unrated = try item("u", server: "a", sort: "a")
        #expect(LibrarySort(key: .rating, descending: false).orders(unrated, before: rated) == true)
        #expect(LibrarySort(key: .rating, descending: true).orders(rated, before: unrated) == true)
    }

    @Test func ascendingStreamsThatOpenWithUnratedItemsStillInterleave() async throws {
        let asc = LibrarySort(key: .rating, descending: false)
        let a = [try item("a0", server: "a", sort: "a0"), try item("a1", server: "a", sort: "a1", rating: 2), try item("a2", server: "a", sort: "a2", rating: 8)]
        let b = [try item("b0", server: "b", sort: "b0"), try item("b1", server: "b", sort: "b1", rating: 5)]
        let pager = MergedPager(sources: [source("a", a, active: true), source("b", b)], sort: asc, pageSize: 10)
        let page = await pager.nextPage()
        #expect(page.map(\.id) == ["a0", "b0", "a1", "b1", "a2"])
    }

    // MARK: I2 / I3

    @Test func returningKeepsPaginatedPages() async throws {
        let a = try (0..<40).map { try item("a\($0)", server: "a", sort: String(format: "a%03d", $0)) }
        let b = try (0..<40).map { try item("b\($0)", server: "b", sort: String(format: "b%03d", $0)) }
        let state = MergedGridState()
        let sources = [source("a", a, active: true), source("b", b)]
        #expect(await state.load(sources: sources, sort: .default, pageSize: 10) == .replaced(cacheable: true))
        #expect(await state.loadMore())
        #expect(state.items.count == 20)
        #expect(await state.load(sources: sources, sort: .default, pageSize: 10) == .kept)
        #expect(state.items.count == 20)
    }

    @Test func aPageFromAReplacedPagerIsDiscarded() async throws {
        let a = try (0..<40).map { try item("a\($0)", server: "a", sort: String(format: "a%03d", $0)) }
        let state = MergedGridState()
        _ = await state.load(sources: [source("a", a, active: true), source("b", [])], sort: .default, pageSize: 10)
        let stale = Task { await state.loadMore() }
        state.reset()
        #expect(await stale.value == false)
        #expect(state.items.isEmpty)
    }

    @Test func anActiveFailureKeepsWhatIsOnScreen() async throws {
        let state = MergedGridState()
        let outcome = await state.load(sources: [source("a", [], active: true, fail: true), source("b", [try item("b1", server: "b", sort: "x")])],
                                       sort: .default, pageSize: 10)
        #expect(outcome == .failed)
        #expect(state.items.isEmpty)
    }

    @Test func aMissingSecondaryIsNotCached() async throws {
        let state = MergedGridState()
        let outcome = await state.load(sources: [source("a", [try item("a1", server: "a", sort: "x")], active: true), source("b", [], fail: true)],
                                       sort: .default, pageSize: 10)
        #expect(outcome == .replaced(cacheable: false))
        #expect(state.items.map(\.id) == ["a1"])
    }

    // MARK: I4

    @Test func providerPhasesDedupeAcrossServers() throws {
        let phase1 = [try item("b1", server: "b", sort: "Heat", tmdb: "949")]
        let phase2 = [try item("a1", server: "a", sort: "Heat", tmdb: "949"), try item("a2", server: "a", sort: "Ronin", tmdb: "8195")]
        let merged = CombinedProviderMatch.mergePhases(phase1: phase1, phase2: phase2)
        #expect(merged.map(\.id) == ["b1", "a2"])
    }

    final class SplitLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var studio: [JellyfinItem] = []
        var scanDelay: Duration = .zero
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            if query.limit == 10000 {
                try? await Task.sleep(for: scanDelay)
                return .init(items: [], totalRecordCount: 0)
            }
            return .init(items: studio, totalRecordCount: studio.count)
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    /// A slow library scan on a secondary must not cost its studio match, and must mark the
    /// result incomplete so it is not cached.
    @Test func aSlowSecondaryScanKeepsItsStudioMatchButIsIncomplete() async throws {
        let a = SplitLibrary()
        let b = SplitLibrary(); b.studio = [try item("b1", server: "b", sort: "Heat")]; b.scanDelay = .seconds(3)
        let sources = [HomeSource(serverID: "a", serverName: "A", userID: "u", libraryService: a, isActive: true),
                       HomeSource(serverID: "b", serverName: "B", userID: "u", libraryService: b, isActive: false)]
        let studioQuery = ItemQuery(includeItemTypes: [.movie], limit: 200, fields: JellyfinEndpoint.homeRowFields)
        let libraryQuery = ItemQuery(includeItemTypes: [.movie], limit: 10000, fields: JellyfinEndpoint.homeRowFields)
        let result = await CombinedProviderMatch.fetch(
            sources: sources, studioQuery: studioQuery, libraryQuery: libraryQuery,
            studioDeadline: .milliseconds(500), scanDeadline: .milliseconds(800))
        #expect(result.phase1?.items.map(\.id) == ["b1"])
        #expect(!result.complete)
    }
}

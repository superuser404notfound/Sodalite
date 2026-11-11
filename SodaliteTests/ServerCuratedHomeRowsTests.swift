import Foundation
import Testing
@testable import Sodalite

/// Home rows on a server that builds its libraries from remote catalogs: `/Items/Latest` may answer
/// `[]` for every library while `/Items` lists them, and the Upcoming list lives in `/Shows/Upcoming`
/// rather than in the schedule query Sodalite reads on Jellyfin.
@MainActor
struct ServerCuratedHomeRowsTests {
    final class FakeLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var latest: [JellyfinItem] = []
        var parentPage: [JellyfinItem] = []
        var recentlyPlayed: [JellyfinItem] = []
        var upcoming: [JellyfinItem] = []
        var itemQueries: [ItemQuery] = []

        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            latest
        }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            itemQueries.append(query)
            if query.filters == ["IsPlayed"] { return .init(items: recentlyPlayed, totalRecordCount: recentlyPlayed.count) }
            if query.parentID != nil, query.sortBy == "DateCreated" { return .init(items: parentPage, totalRecordCount: parentPage.count) }
            return .init(items: [], totalRecordCount: 0)
        }
        func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem] { upcoming }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func movie(_ id: String, premiere: String? = nil, played: Bool = false) throws -> JellyfinItem {
        let date = premiere.map { #","PremiereDate":"\#($0)T00:00:00.0000000Z""# } ?? ""
        return try item(#"{"Id":"\#(id)","Name":"Film \#(id)","Type":"Movie","UserData":{"Played":\#(played)}\#(date)}"#)
    }

    private func episode(_ id: String, series: String, premiere: String? = nil, played: Bool = false) throws -> JellyfinItem {
        let date = premiere.map { #","PremiereDate":"\#($0)T00:00:00.0000000Z""# } ?? ""
        return try item(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode","SeriesId":"\#(series)","SeriesName":"Show \#(series)","UserData":{"Played":\#(played)}\#(date)}"#)
    }

    private func model(_ library: FakeLibrary) -> HomeViewModel {
        HomeViewModel(
            libraryService: library,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u", serverID: "srv-\(UUID().uuidString)")
    }

    private func isoDay(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    // MARK: - Latest fallback

    @Test func anEmptyLatestFallsBackToTheLibrarysFirstPage() async throws {
        let library = FakeLibrary()
        library.parentPage = try [movie("a"), movie("b")]
        let config = HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 0, libraryID: "lib", libraryName: "Popular", collectionType: "movies")
        let vm = model(library)
        let row = try await vm.loadRow(config: config, source: vm.sources[0])
        #expect(row?.items.map(\.id) == ["a", "b"])
        let query = try #require(library.itemQueries.first { $0.sortBy == "DateCreated" })
        #expect(query.parentID == "lib")
        #expect(query.sortOrder == "Descending")
        #expect(query.fields == JellyfinEndpoint.homeRowFields)
    }

    @Test func aFilledLatestIsNotReadTwice() async throws {
        let library = FakeLibrary()
        library.latest = try [movie("new")]
        library.parentPage = try [movie("other")]
        let config = HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 0, libraryID: "lib", libraryName: "Movies", collectionType: "movies")
        let vm = model(library)
        let row = try await vm.loadRow(config: config, source: vm.sources[0])
        #expect(row?.items.map(\.id) == ["new"])
        #expect(!library.itemQueries.contains { $0.sortBy == "DateCreated" })
    }

    // MARK: - Upcoming from /Shows/Upcoming

    @Test func serverListAddsUnreleasedFilmsAndCaughtUpEpisodes() throws {
        let now = Date()
        let list = try [
            episode("e1", series: "caught", premiere: isoDay(3)),
            episode("e2", series: "behind", premiere: isoDay(2)),
            movie("soon", premiere: isoDay(10)),
            movie("out", premiere: isoDay(-5)),
            movie("seen", premiere: isoDay(4), played: true),
            movie("undated"),
        ]
        let added = HomeUpcoming.fromServerList(list, found: [], caughtUp: ["caught"], now: now, calendar: .current)
        #expect(added.map(\.id) == ["e1", "soon"])
    }

    @Test func serverListLeavesAShowTheScheduleAlreadyCovered() throws {
        let found = try [episode("lib", series: "caught", premiere: isoDay(1))]
        let list = try [episode("srv", series: "caught", premiere: isoDay(8)), movie("lib-dupe", premiere: isoDay(2))]
        let added = HomeUpcoming.fromServerList(list, found: found, caughtUp: ["caught"], now: Date(), calendar: .current)
        #expect(added.map(\.id) == ["lib-dupe"])
    }

    @Test func theRowReadsTheServersUpcomingList() async throws {
        let library = FakeLibrary()
        library.recentlyPlayed = try [episode("old", series: "caught", played: true)]
        library.upcoming = try [movie("film", premiere: isoDay(20)), episode("next", series: "caught", premiere: isoDay(6))]
        let vm = model(library)
        let items = try await vm.loadUpcoming(source: vm.sources[0])
        #expect(items.map(\.id) == ["next", "film"])
    }

    @Test func upcomingEndpointAsksForCardFields() {
        let endpoint = JellyfinEndpoint.upcoming(userID: "u", limit: 100)
        #expect(endpoint.path == "/Shows/Upcoming")
        let items = endpoint.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "UserId", value: "u")))
        #expect(items.contains(URLQueryItem(name: "Limit", value: "100")))
        #expect(items.contains(URLQueryItem(name: "Fields", value: JellyfinEndpoint.homeRowFields)))
    }
}

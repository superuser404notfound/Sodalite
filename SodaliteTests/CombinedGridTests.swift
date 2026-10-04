import Foundation
import Testing
@testable import Sodalite

@MainActor
struct CombinedGridTests {
    final class GridLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var all: [JellyfinItem] = []
        var queries: [ItemQuery] = []
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            queries.append(query)
            let start = query.startIndex ?? 0
            return JellyfinItemsResponse(items: Array(all.dropFirst(start).prefix(query.limit ?? all.count)), totalRecordCount: all.count)
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    @Test func pagerSourcesCarryTheGridQueryToEachServerWithItsUser() async throws {
        let a = GridLibrary(); let b = GridLibrary()
        b.all = [try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"b1","Name":"x","Type":"Movie"}"#.utf8))]
        let sources = [HomeSource(serverID: "a", serverName: "A", userID: "u-a", libraryService: a, isActive: true),
                       HomeSource(serverID: "b", serverName: "B", userID: "u-b", libraryService: b, isActive: false)]
        let query = ItemQuery(includeItemTypes: [.movie], sortBy: "SortName", sortOrder: "Ascending", limit: 50,
                              genres: ["Drama"], fields: JellyfinEndpoint.homeRowFields)
        let pagerSources = MergedPager.sources(from: sources, query: query)
        let page = await MergedPager(sources: pagerSources, sort: .default, pageSize: 50).nextPage()
        #expect(page.map(\.serverID) == ["b"])
        #expect(b.queries.first?.genres == ["Drama"])
        #expect(b.queries.first?.startIndex == 0)
    }
}

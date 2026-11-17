import Foundation
import Testing
@testable import Sodalite

/// BRW-202: a failed Seerr lookup must not be remembered as "no next episode".
@MainActor
struct UpcomingSeerrLookupTests {
    final class Library: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        let played: [JellyfinItem]
        let series: [JellyfinItem]
        init(played: [JellyfinItem], series: [JellyfinItem]) { self.played = played; self.series = series }

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            if query.filters == ["IsPlayed"] { return .init(items: played, totalRecordCount: played.count) }
            if query.ids != nil { return .init(items: series, totalRecordCount: series.count) }
            return .init(items: [], totalRecordCount: 0)
        }
        func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func model() throws -> HomeViewModel {
        let library = Library(
            played: [try item(#"{"Id":"e1","Name":"E","Type":"Episode","SeriesId":"s1","SeriesName":"Show","UserData":{"Played":true}}"#)],
            series: [try item(#"{"Id":"s1","Name":"Show","Type":"Series","ProviderIds":{"Tmdb":"42"}}"#)]
        )
        return HomeViewModel(
            libraryService: library,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u", serverID: "srv-\(UUID().uuidString)")
    }

    @Test func aThrowingLookupIsNotCached() async throws {
        let vm = try model()
        vm.nextAiringLookup = { _ in throw SeerrLookupUnavailable() }
        _ = try await vm.loadUpcoming(source: vm.sources[0])
        #expect(vm.nextAiringCache.isEmpty)
    }

    @Test func anEmptyAnswerIsCached() async throws {
        let vm = try model()
        vm.nextAiringLookup = { _ in nil }
        _ = try await vm.loadUpcoming(source: vm.sources[0])
        #expect(vm.nextAiringCache[42] != nil)
    }
}

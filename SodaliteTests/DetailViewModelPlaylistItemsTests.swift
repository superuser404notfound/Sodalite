import Testing
import Foundation
@testable import Sodalite

/// A playlist reads `/Playlists/{id}/Items`, which keeps the order the user arranged on the server
/// (`/Items?ParentId=` does not promise one), and pages past the first 200 entries.
@MainActor
struct DetailViewModelPlaylistItemsTests {
    struct NotUsed: Error {}

    final class MockItemService: JellyfinItemServiceProtocol, @unchecked Sendable {
        var playlist: [JellyfinItem] = []
        var pageRequests: [(startIndex: Int, limit: Int)] = []
        var collectionRequests = 0

        func getPlaylistItems(playlistID: String, userID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse {
            pageRequests.append((startIndex, limit))
            let page = Array(playlist.dropFirst(startIndex).prefix(limit))
            return JellyfinItemsResponse(items: page, totalRecordCount: playlist.count)
        }
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            collectionRequests += 1
            throw NotUsed()
        }
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw NotUsed() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func setRating(userID: String, itemID: String, rating: Double?) async throws {}
        func clearPlaybackPosition(userID: String, itemID: String) async throws {}
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(
            userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?
        ) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {}
    }

    private func decodeItem(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func makeViewModel(service: MockItemService) throws -> DetailViewModel {
        DetailViewModel(
            item: try decodeItem(#"{"Id":"pl1","Name":"Playlist","Type":"Playlist"}"#),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
    }

    @Test("the playlist keeps the server's order, deliberately not alphabetical")
    func keepsServerOrder() async throws {
        let service = MockItemService()
        service.playlist = try ["Zulu", "Alpha", "Mike"].map {
            try decodeItem(#"{"Id":"\#($0)","Name":"\#($0)","Type":"Movie"}"#)
        }
        let vm = try makeViewModel(service: service)

        await vm.loadPlaylistItems()

        #expect(vm.collectionItems.map(\.id) == ["Zulu", "Alpha", "Mike"])
        #expect(service.collectionRequests == 0)
    }

    @Test("a playlist longer than one page is read to the end, in order")
    func pagesPastTheFirstPage() async throws {
        let service = MockItemService()
        service.playlist = try (0..<450).map {
            try decodeItem(#"{"Id":"m\#($0)","Name":"M\#($0)","Type":"Movie"}"#)
        }
        let vm = try makeViewModel(service: service)

        await vm.loadPlaylistItems()

        #expect(vm.collectionItems.map(\.id) == (0..<450).map { "m\($0)" })
        #expect(service.pageRequests.map(\.startIndex) == [0, 200, 400])
    }

    @Test("the endpoint is the playlist one")
    func endpointContract() {
        let endpoint = JellyfinEndpoint.playlistItems(playlistID: "pl1", userID: "u1", startIndex: 200, limit: 200)
        #expect(endpoint.path == "/Playlists/pl1/Items")
        let query = Dictionary(uniqueKeysWithValues: (endpoint.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(query["UserId"] == "u1")
        #expect(query["StartIndex"] == "200")
        #expect(query["Limit"] == "200")
        #expect(query["Fields"] == JellyfinEndpoint.detailFields)
    }
}

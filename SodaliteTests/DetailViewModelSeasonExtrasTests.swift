import Testing
import Foundation
@testable import Sodalite

/// Sodalite#243. A season's `extras` folder belongs to the season, not the show, so the series page
/// never asked for it and the row was missing while the Jellyfin app showed it.
@MainActor
struct DetailViewModelSeasonExtrasTests {
    struct ServiceFailure: Error {}

    final class MockItemService: JellyfinItemServiceProtocol, @unchecked Sendable {
        var extrasByItem: [String: [JellyfinItem]] = [:]
        var failingItems: Set<String> = []
        private(set) var specialFeatureRequests: [String] = []

        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] {
            specialFeatureRequests.append(itemID)
            if failingItems.contains(itemID) { throw ServiceFailure() }
            return extrasByItem[itemID] ?? []
        }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw ServiceFailure() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
        func getPlaylistItems(playlistID: String, userID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func setRating(userID: String, itemID: String, rating: Double?) async throws {}
        func clearPlaybackPosition(userID: String, itemID: String) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
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

    private func season(_ id: String, extras: Int) throws -> JellyfinItem {
        try decodeItem("{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Season\",\"SpecialFeatureCount\":\(extras)}")
    }

    private func extra(_ id: String) throws -> JellyfinItem {
        try decodeItem("{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Video\"}")
    }

    private func makeViewModel(service: MockItemService) throws -> DetailViewModel {
        DetailViewModel(
            item: try decodeItem(#"{"Id":"series1","Name":"Show","Type":"Series"}"#),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
    }

    /// The fetch is a detached task; give it a few main-actor turns to land.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("the selected season's extras load and follow the selection", .timeLimit(.minutes(1)))
    func extrasFollowTheSelectedSeason() async throws {
        let service = MockItemService()
        service.extrasByItem = ["s1": [try extra("x1")], "s2": [try extra("x2"), try extra("x3")]]
        let vm = try makeViewModel(service: service)
        vm.seasons = [try season("s1", extras: 1), try season("s2", extras: 2)]

        vm.selectedSeasonID = "s1"
        await settle { !vm.selectedSeasonExtras.isEmpty }
        #expect(vm.selectedSeasonExtras.map(\.id) == ["x1"])

        vm.selectedSeasonID = "s2"
        await settle { vm.selectedSeasonExtras.count == 2 }
        #expect(vm.selectedSeasonExtras.map(\.id) == ["x2", "x3"])

        // Back to season 1 comes from the cache.
        vm.selectedSeasonID = "s1"
        #expect(vm.selectedSeasonExtras.map(\.id) == ["x1"])
        #expect(service.specialFeatureRequests == ["s1", "s2"])
    }

    @Test("a season without extras sends no request", .timeLimit(.minutes(1)))
    func seasonWithoutExtrasSendsNoRequest() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service)
        vm.seasons = [try season("s1", extras: 0)]
        vm.selectedSeasonID = "s1"
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.specialFeatureRequests.isEmpty)
        #expect(vm.selectedSeasonExtras.isEmpty)
    }

    @Test("a selection made before the season list arrives still loads", .timeLimit(.minutes(1)))
    func selectionBeforeSeasonList() async throws {
        let service = MockItemService()
        service.extrasByItem = ["s2": [try extra("x2")]]
        let vm = try makeViewModel(service: service)

        // An episode deep link selects its season while getSeasons is still out.
        vm.selectedSeasonID = "s2"
        #expect(service.specialFeatureRequests.isEmpty)
        vm.seasons = [try season("s1", extras: 0), try season("s2", extras: 1)]
        await settle { !vm.selectedSeasonExtras.isEmpty }
        #expect(vm.selectedSeasonExtras.map(\.id) == ["x2"])
    }

    @Test("a failed fetch is retried on the next selection", .timeLimit(.minutes(1)))
    func failedFetchRetries() async throws {
        let service = MockItemService()
        service.extrasByItem = ["s1": [try extra("x1")]]
        service.failingItems = ["s1"]
        let vm = try makeViewModel(service: service)
        vm.seasons = [try season("s1", extras: 1), try season("s2", extras: 0)]

        vm.selectedSeasonID = "s1"
        await settle { service.specialFeatureRequests.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(vm.selectedSeasonExtras.isEmpty)

        service.failingItems = []
        vm.selectedSeasonID = "s2"
        vm.selectedSeasonID = "s1"
        await settle { !vm.selectedSeasonExtras.isEmpty }
        #expect(vm.selectedSeasonExtras.map(\.id) == ["x1"])
    }
}

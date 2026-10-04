import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 BROWSE-7. `refreshSeasons()` reloaded the season tabs after a seasons-only
/// delete but left `nextUpEpisode` / `currentEpisodeID` / `cachedPlaybackInfo` exactly as they were,
/// so Play kept a deleted episode as its target, prefetched PlaybackInfo included, and launched a
/// file the server had just removed.
@MainActor
struct DetailViewModelRefreshSeasonsTests {
    struct ServiceFailure: Error {}

    /// Only `getSeasons` and `getEpisodes` carry behaviour; refreshSeasons() is the only path under
    /// test.
    final class MockItemService: JellyfinItemServiceProtocol, @unchecked Sendable {
        var seasons: [JellyfinItem] = []

        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: seasons, totalRecordCount: seasons.count)
        }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw ServiceFailure() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
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

    private func season(_ id: String) throws -> JellyfinItem {
        try decodeItem("{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Season\"}")
    }

    private func episode(_ id: String, seasonID: String) throws -> JellyfinItem {
        try decodeItem(
            "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Episode\",\"SeasonId\":\"\(seasonID)\"}"
        )
    }

    private func makeViewModel(service: MockItemService) throws -> DetailViewModel {
        DetailViewModel(
            item: try decodeItem(#"{"Id":"series1","Name":"Show","Type":"Series"}"#),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
    }

    @Test("deleting Next Up's season clears the play target and its prefetched PlaybackInfo")
    func deletingNextUpsSeasonClearsThePlayTarget() async throws {
        let service = MockItemService()
        service.seasons = [try season("s1"), try season("s2")]
        let vm = try makeViewModel(service: service)

        let nextUp = try episode("e_s2e3", seasonID: "s2")
        vm.nextUpEpisode = nextUp
        vm.currentEpisodeID = nextUp.id
        vm.cachedPlaybackInfo = PrefetchedPlaybackInfo(
            itemID: nextUp.id, quality: .original, response: PlaybackInfoResponse(mediaSources: [], playSessionId: nil)
        )
        vm.selectedSeasonID = "s2"

        // Season 2 (Next Up's season) was deleted.
        service.seasons = [try season("s1")]
        await vm.refreshSeasons()

        #expect(vm.nextUpEpisode == nil, "nextUpEpisode still pointed at the deleted season")
        #expect(vm.currentEpisodeID == nil, "currentEpisodeID still pointed at the deleted episode")
        #expect(vm.cachedPlaybackInfo == nil, "cachedPlaybackInfo still carried the deleted episode")
        #expect(vm.selectedSeasonID == "s1", "the surviving season was not selected")
    }

    @Test("deleting an unrelated season leaves the play target alone")
    func deletingAnUnrelatedSeasonLeavesThePlayTargetAlone() async throws {
        let service = MockItemService()
        service.seasons = [try season("s1"), try season("s2"), try season("s3")]
        let vm = try makeViewModel(service: service)

        let nextUp = try episode("e_s2e3", seasonID: "s2")
        vm.nextUpEpisode = nextUp
        vm.currentEpisodeID = nextUp.id
        vm.cachedPlaybackInfo = PrefetchedPlaybackInfo(
            itemID: nextUp.id, quality: .original, response: PlaybackInfoResponse(mediaSources: [], playSessionId: nil)
        )

        // Season 3 was deleted; Next Up's own season (2) survives.
        service.seasons = [try season("s1"), try season("s2")]
        await vm.refreshSeasons()

        #expect(vm.nextUpEpisode?.id == "e_s2e3")
        #expect(vm.currentEpisodeID == "e_s2e3")
        #expect(vm.cachedPlaybackInfo?.itemID == "e_s2e3")
    }
}

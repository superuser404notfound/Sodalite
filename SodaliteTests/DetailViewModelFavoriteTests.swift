import Testing
import Foundation
@testable import Sodalite

/// Per-episode favorites: the override map is the live source for the card badge and the panel
/// button, because the immutable JellyfinItem's userData cannot change in-session. A failed server
/// write must leave no trace, else the badge lies about what the server stores.
@MainActor
struct DetailViewModelFavoriteTests {
    struct ServiceFailure: Error {}

    /// Only `setFavorite` carries behaviour; every other member exists to satisfy the protocol and
    /// throws, since these tests never load detail, seasons or episodes. Returning an empty
    /// `JellyfinItemsResponse` is not an option: with MainActor default isolation its Decodable
    /// conformance is actor-isolated and unreachable from these nonisolated protocol methods.
    final class MockItemService: JellyfinItemServiceProtocol, @unchecked Sendable {
        var shouldThrow = false
        var favoriteCalls: [(itemID: String, isFavorite: Bool)] = []

        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {
            if shouldThrow { throw ServiceFailure() }
            favoriteCalls.append((itemID, isFavorite))
        }

        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
            throw ServiceFailure()
        }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw ServiceFailure()
        }
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

    private func makeViewModel(service: MockItemService) throws -> DetailViewModel {
        DetailViewModel(
            item: try decodeItem(#"{"Id":"series1","Name":"Show","Type":"Series"}"#),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
    }

    @Test func favoriteFallsBackToServerSnapshotWhenNoOverride() throws {
        let vm = try makeViewModel(service: MockItemService())
        let favorited = try decodeItem(
            #"{"Id":"e1","Name":"E1","Type":"Episode","UserData":{"IsFavorite":true}}"#)
        let plain = try decodeItem(#"{"Id":"e2","Name":"E2","Type":"Episode"}"#)
        #expect(vm.isFavorite(favorited))
        #expect(!vm.isFavorite(plain))
    }

    @Test func overrideWinsOverServerSnapshotInBothDirections() throws {
        let vm = try makeViewModel(service: MockItemService())
        let favorited = try decodeItem(
            #"{"Id":"e1","Name":"E1","Type":"Episode","UserData":{"IsFavorite":true}}"#)
        let plain = try decodeItem(#"{"Id":"e2","Name":"E2","Type":"Episode"}"#)

        vm.favoriteOverrides["e1"] = false
        vm.favoriteOverrides["e2"] = true
        #expect(!vm.isFavorite(favorited))
        #expect(vm.isFavorite(plain))
    }

    @Test func setEpisodeFavoriteWritesThroughAndKeepsOverride() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service)
        let episode = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode"}"#)

        await vm.setEpisodeFavorite(episode, isFavorite: true)

        #expect(service.favoriteCalls.count == 1)
        #expect(service.favoriteCalls.first?.itemID == "e1")
        #expect(service.favoriteCalls.first?.isFavorite == true)
        #expect(vm.isFavorite(episode))
    }

    /// Rollback to *absent*, not to false: a previously untouched episode whose write fails must
    /// fall back to the server snapshot again, not get pinned to a client-side "not favorite".
    @Test func failedWriteRemovesTheOverrideEntirely() async throws {
        let service = MockItemService()
        service.shouldThrow = true
        let vm = try makeViewModel(service: service)
        let episode = try decodeItem(
            #"{"Id":"e1","Name":"E1","Type":"Episode","UserData":{"IsFavorite":true}}"#)

        await vm.setEpisodeFavorite(episode, isFavorite: false)

        #expect(vm.favoriteOverrides["e1"] == nil)
        #expect(vm.isFavorite(episode))
    }

    /// A failed second toggle restores the value the first (successful) toggle established.
    @Test func failedWriteRestoresPreviousOverrideValue() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service)
        let episode = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode"}"#)

        await vm.setEpisodeFavorite(episode, isFavorite: true)
        service.shouldThrow = true
        await vm.setEpisodeFavorite(episode, isFavorite: false)

        #expect(vm.favoriteOverrides["e1"] == true)
        #expect(vm.isFavorite(episode))
    }

    /// The episode path must not disturb the series-level flag the same screen renders.
    @Test func episodeFavoriteLeavesTopLevelFlagAlone() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service)
        let episode = try decodeItem(#"{"Id":"e1","Name":"E1","Type":"Episode"}"#)

        #expect(!vm.isFavorite)
        await vm.setEpisodeFavorite(episode, isFavorite: true)
        #expect(!vm.isFavorite)
    }
}

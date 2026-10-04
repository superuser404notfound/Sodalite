import Testing
import Foundation
@testable import Sodalite

/// Sodalite#179. The Extras row reads `/SpecialFeatures`, and only for an item whose detail reports
/// a SpecialFeatureCount, so a page without extras costs no extra round trip.
@MainActor
struct DetailViewModelSpecialFeaturesTests {
    struct ServiceFailure: Error {}

    final class MockItemService: JellyfinItemServiceProtocol, @unchecked Sendable {
        var detail: JellyfinItem?
        var extras: [JellyfinItem] = []
        var specialFeatureRequests: [String] = []

        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
            guard let detail else { throw ServiceFailure() }
            return detail
        }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] {
            specialFeatureRequests.append(itemID)
            return extras
        }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
            JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }
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

    private func makeViewModel(service: MockItemService) throws -> DetailViewModel {
        DetailViewModel(
            item: try decodeItem(#"{"Id":"movie1","Name":"Movie","Type":"Movie"}"#),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
    }

    @Test("a detail with a SpecialFeatureCount fills the Extras row")
    func countFetchesTheExtras() async throws {
        let service = MockItemService()
        service.detail = try decodeItem(#"{"Id":"movie1","Name":"Movie","Type":"Movie","SpecialFeatureCount":2}"#)
        service.extras = [
            try decodeItem(#"{"Id":"clip1","Name":"Opening","Type":"Video","ExtraType":"Clip"}"#),
            try decodeItem(#"{"Id":"bts1","Name":"Making of","Type":"Video","ExtraType":"BehindTheScenes"}"#),
        ]
        let vm = try makeViewModel(service: service)

        await vm.loadFullDetail()
        for _ in 0..<200 where vm.specialFeatures.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(vm.item.specialFeatureCount == 2)
        #expect(vm.specialFeatures.map(\.id) == ["clip1", "bts1"])
        #expect(service.specialFeatureRequests == ["movie1"])
    }

    @Test("a detail without extras never asks for them")
    func noCountNoRequest() async throws {
        let service = MockItemService()
        service.detail = try decodeItem(#"{"Id":"movie1","Name":"Movie","Type":"Movie","SpecialFeatureCount":0}"#)
        let vm = try makeViewModel(service: service)

        await vm.loadFullDetail()
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.specialFeatures.isEmpty)
        #expect(service.specialFeatureRequests.isEmpty)
    }

    @Test("the detail fetch asks for the count and the row hits SpecialFeatures")
    func endpointContract() {
        let fields = Set(JellyfinEndpoint.detailFields.split(separator: ",").map(String.init))
        #expect(fields.contains("SpecialFeatureCount"))
        #expect(JellyfinEndpoint.specialFeatures(userID: "u1", itemID: "m1").path == "/Users/u1/Items/m1/SpecialFeatures")
    }
}

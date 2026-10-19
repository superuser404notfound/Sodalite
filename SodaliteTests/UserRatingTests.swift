import Testing
import Foundation
@testable import Sodalite

/// The viewer's own rating (Sodalite#48): Jellyfin's `UserData.Rating`, written through the UserData
/// POST and cleared through `DELETE /UserItems/{id}/Rating`.
@MainActor
struct UserRatingTests {
    typealias MockItemService = DetailViewModelFavoriteTests.MockItemService

    private func decodeItem(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func makeViewModel(service: MockItemService, userData: String = "{}") throws -> DetailViewModel {
        DetailViewModel(
            item: try decodeItem(#"{"Id":"m1","Name":"Film","Type":"Movie","UserData":"# + userData + "}"),
            itemService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )
    }

    @Test func decodesTheServersRating() throws {
        let item = try decodeItem(#"{"Id":"m1","Name":"Film","Type":"Movie","UserData":{"Rating":8,"Likes":true,"Played":true}}"#)
        #expect(item.userData?.rating == 8)
    }

    @Test func resumePatchKeepsTheRating() throws {
        var item = try decodeItem(#"{"Id":"m1","Name":"Film","Type":"Movie","RunTimeTicks":1000,"UserData":{"Rating":7.5}}"#)
        item.setResumePosition(100)
        #expect(item.userData?.rating == 7.5)
    }

    @Test func viewModelStartsFromTheItemsRating() throws {
        #expect(try makeViewModel(service: MockItemService(), userData: #"{"Rating":6}"#).rating == 6)
        #expect(try makeViewModel(service: MockItemService()).rating == nil)
    }

    @Test func setRatingWritesThrough() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service)
        await vm.setRating(9)
        #expect(vm.rating == 9)
        #expect(service.ratingCalls.count == 1)
        #expect(service.ratingCalls.first?.itemID == "m1")
        #expect(service.ratingCalls.first?.rating == 9)
    }

    @Test func clearingSendsNil() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service, userData: #"{"Rating":4}"#)
        await vm.setRating(nil)
        #expect(vm.rating == nil)
        #expect(service.ratingCalls.count == 1)
        #expect(service.ratingCalls.first?.rating == nil)
    }

    @Test func unchangedValueSendsNothing() async throws {
        let service = MockItemService()
        let vm = try makeViewModel(service: service, userData: #"{"Rating":4}"#)
        await vm.setRating(4)
        #expect(service.ratingCalls.isEmpty)
    }

    @Test func failedWriteRollsBack() async throws {
        let service = MockItemService()
        service.shouldThrow = true
        let vm = try makeViewModel(service: service, userData: #"{"Rating":5}"#)
        await vm.setRating(10)
        #expect(vm.rating == 5)
    }

    @Test func clearUsesTheRatingEndpointNotTheLikesQuery() {
        let endpoint = JellyfinEndpoint.clearUserRating(itemID: "m1", userID: "u1")
        #expect(endpoint.path == "/UserItems/m1/Rating")
        #expect(endpoint.method == .delete)
        #expect(endpoint.queryItems == [URLQueryItem(name: "userId", value: "u1")])
    }
}

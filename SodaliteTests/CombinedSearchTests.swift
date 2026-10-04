import Foundation
import Testing
@testable import Sodalite

@MainActor
struct CombinedSearchTests {
    final class FakeItems: JellyfinItemServiceProtocol, @unchecked Sendable {
        var items: [JellyfinItem] = []
        var delay: Duration = .zero
        var fail = false
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if fail { throw URLError(.cannotConnectToHost) }
            return JellyfinItemsResponse(items: items, totalRecordCount: items.count)
        }
        struct NotUsed: Error {}
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw NotUsed() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(
            userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?
        ) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {}
    }

    private func item(_ id: String, server: String, sort: String, tmdb: String? = nil) throws -> JellyfinItem {
        let ids = tmdb.map { #","ProviderIds":{"Tmdb":"\#($0)"}"# } ?? ""
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(sort)","SortName":"\#(sort)","Type":"Movie","ServerId":"\#(server)"\#(ids)}"#.utf8))
    }

    private func model(_ a: FakeItems, _ b: FakeItems) -> SearchViewModel {
        let vm = SearchViewModel(
            itemService: a, seerrSearchService: nil, userID: "u-a",
            sources: [SearchSource(serverID: "a", userID: "u-a", itemService: a, isActive: true),
                      SearchSource(serverID: "b", userID: "u-b", itemService: b, isActive: false)])
        vm.secondaryDeadline = .milliseconds(300)
        return vm
    }

    private func search(_ vm: SearchViewModel, _ text: String) async {
        vm.query = text
        vm.scheduleSearch()
        try? await Task.sleep(for: .milliseconds(1200))
    }

    @Test func resultsFromBothServersMergeBySortName() async throws {
        let a = FakeItems(); a.items = [try item("a1", server: "a", sort: "Zulu")]
        let b = FakeItems(); b.items = [try item("b1", server: "b", sort: "Alpha")]
        let vm = model(a, b)
        await search(vm, "xx")
        #expect(vm.jellyfinResults.map(\.id) == ["b1", "a1"])
    }

    @Test func theSameTitleOnBothServersAppearsOnce() async throws {
        let a = FakeItems(); a.items = [try item("a1", server: "a", sort: "Heat", tmdb: "949")]
        let b = FakeItems(); b.items = [try item("b1", server: "b", sort: "Heat", tmdb: "949")]
        let vm = model(a, b)
        await search(vm, "heat")
        #expect(vm.jellyfinResults.map(\.originKey) == ["a|a1"])
    }

    @Test func slowSecondaryDoesNotHoldSearch() async throws {
        let a = FakeItems(); a.items = [try item("a1", server: "a", sort: "Heat")]
        let b = FakeItems(); b.delay = .seconds(5)
        let vm = model(a, b)
        let clock = ContinuousClock()
        let start = clock.now
        await search(vm, "heat")
        #expect(vm.jellyfinResults.map(\.id) == ["a1"])
        #expect(clock.now - start < .seconds(3))
        #expect(vm.errorMessage == nil)
    }

    @Test func failingSecondaryIsSilentButFailingActiveStillReports() async throws {
        let a = FakeItems(); a.fail = true
        let b = FakeItems(); b.items = [try item("b1", server: "b", sort: "Heat")]
        let vm = model(a, b)
        await search(vm, "heat")
        #expect(vm.jellyfinResults.map(\.id) == ["b1"])
        #expect(vm.errorMessage == nil)
    }

    @Test func oneSourceIsTodaysPath() async throws {
        let a = FakeItems(); a.items = [try item("a1", server: "a", sort: "Heat")]
        let vm = SearchViewModel(itemService: a, seerrSearchService: nil, userID: "u-a")
        await search(vm, "heat")
        #expect(vm.jellyfinResults.map(\.id) == ["a1"])
        #expect(vm.sources.count == 1)
    }
}

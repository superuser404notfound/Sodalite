import Testing
import Foundation
@testable import Sodalite

/// Home used to latch a config change into `needsReload` and consume it in `onAppear`. That works
/// when Settings is a tab (tvOS: leaving it re-appears Home), but on iOS Settings is a sheet over the
/// TabView, and a sheet dismiss fires no `onAppear` on the view underneath (measured on iOS 26), so
/// the flag stayed pending until the app was relaunched. Reloading is now scheduled directly and
/// coalesced, because Home Customize posts one notification per toggle.
@MainActor
struct HomeConfigReloadTests {
    final class MockLibraryService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        /// loadContent() always starts with getLibraries, so this counts reloads.
        var getLibrariesCalls = 0

        /// Decoded on the MainActor by the test and handed over, because the model's Decodable
        /// conformance is actor-isolated and these protocol methods are not. nil makes getItems throw.
        var itemsResponse: JellyfinItemsResponse?

        struct Unused: Error {}

        /// Throws so loadContent skips reconciliation and leaves the test's rowConfigs alone.
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            getLibrariesCalls += 1
            throw Unused()
        }

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            guard let itemsResponse else { throw Unused() }
            return itemsResponse
        }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            []
        }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func makeViewModel(service: MockLibraryService) -> HomeViewModel {
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: "s1"
        )
        // Keep the coalescing window short so these tests stay fast.
        vm.configReloadDebounce = .milliseconds(30)
        return vm
    }

    /// Long enough for the debounce window plus the (service-stubbed) load to finish.
    private func waitForReload() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    @Test func configChangeTriggersAReloadWithoutAnyOnAppear() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        vm.scheduleConfigReload()
        await waitForReload()

        #expect(service.getLibrariesCalls == 1)
    }

    /// Home Customize posts one notification per toggle; flipping several rows must not fan out one
    /// full home reload per toggle.
    @Test func burstOfConfigChangesCoalescesIntoOneReload() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        for _ in 0..<5 {
            vm.scheduleConfigReload()
        }
        await waitForReload()

        #expect(service.getLibrariesCalls == 1)
    }

    /// A change arriving after the previous reload already ran must schedule a fresh one, not be
    /// swallowed as a duplicate.
    @Test func laterConfigChangeSchedulesAnotherReload() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        vm.scheduleConfigReload()
        await waitForReload()
        vm.scheduleConfigReload()
        await waitForReload()

        #expect(service.getLibrariesCalls == 2)
    }

    /// BRW-207: the offline progress sync posts one notification per item; Home must answer a burst
    /// with one load.
    @Test func burstOfProgressNotificationsCoalescesIntoOneReload() async {
        let service = MockLibraryService()
        let vm = makeViewModel(service: service)

        for index in 0..<5 {
            vm.scheduleReload(applying: ("item-\(index)", Int64(index)))
        }
        await waitForReload()

        #expect(service.getLibrariesCalls == 1)
    }

    private func decodeResponse(_ json: String) throws -> JellyfinItemsResponse {
        try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(json.utf8))
    }

    private func viewModelShowingOneFavoriteEpisode(
        service: MockLibraryService
    ) async throws -> HomeViewModel {
        service.itemsResponse = try decodeResponse(
            #"{"Items":[{"Id":"e1","Name":"E1","Type":"Episode"}],"TotalRecordCount":1}"#)
        let vm = makeViewModel(service: service)
        vm.rowConfigs = [HomeRowConfig(type: .favoriteEpisodes, isEnabled: true, sortOrder: 0)]
        await vm.loadContent()
        #expect(vm.rows.contains { $0.type == .favoriteEpisodes })
        return vm
    }

    /// Unfavoriting the last episode: the server correctly returns zero items (verified on device),
    /// but the row kept its previous items because a successful-but-empty result hit the same
    /// `case .empty: break` as a failed fetch, so the stale card stayed until the app was relaunched.
    @Test func rowThatBecameEmptyIsRemoved() async throws {
        let service = MockLibraryService()
        let vm = try await viewModelShowingOneFavoriteEpisode(service: service)

        service.itemsResponse = try decodeResponse(#"{"Items":[],"TotalRecordCount":0}"#)
        await vm.loadContent()

        #expect(!vm.rows.contains { $0.type == .favoriteEpisodes })
    }

    /// The other half of the contract: a failed refresh must NOT wipe on-screen rows, so a transient
    /// CDN hiccup doesn't blank Home. This is why "empty" and "failed" have to stay distinguishable.
    @Test func rowSurvivesAFailedRefresh() async throws {
        let service = MockLibraryService()
        let vm = try await viewModelShowingOneFavoriteEpisode(service: service)

        service.itemsResponse = nil
        await vm.loadContent()

        #expect(vm.rows.contains { $0.type == .favoriteEpisodes })
        #expect(vm.rows.first { $0.type == .favoriteEpisodes }?.items.count == 1)
    }
}

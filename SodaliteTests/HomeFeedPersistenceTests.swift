import Testing
import Foundation
@testable import Sodalite

/// Sodalite#117. Home kept its rows in memory only, so every launch and every server switch
/// repainted the whole shelf from the network, from a blank screen. The feed is persisted per
/// identity now and hydrated in `init`, the way the grids already hydrate from their own slice.
///
/// These run against `FilterCache.shared`, which is what the view model reads, with a fresh
/// identity per test and an evict on the way out.
@MainActor
struct HomeFeedPersistenceTests {

    /// Answers Continue Watching and nothing else. `failsEverything` is the unreachable server: it
    /// throws from every endpoint, because an endpoint that returns an empty array has ANSWERED and
    /// must not read as a failure.
    final class FeedService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        let resumeItems: [JellyfinItem]
        let failsEverything: Bool

        init(resumeItems: [JellyfinItem], failsEverything: Bool = false) {
            self.resumeItems = resumeItems
            self.failsEverything = failsEverything
        }

        struct Unused: Error {}

        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            if failsEverything { throw Unused() }
            return JellyfinItemsResponse(items: resumeItems, totalRecordCount: resumeItems.count)
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            if failsEverything { throw Unused() }
            return []
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw Unused() }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Unused() }
        func getGenres(userID: String) async throws -> [NamedItem] { throw Unused() }
        func getStudios(userID: String) async throws -> [NamedItem] { throw Unused() }
    }

    private func item(_ id: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: id)
    }

    private func makeViewModel(service: FeedService, identity: CacheIdentity) -> HomeViewModel {
        HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: identity.userID,
            serverID: identity.serverID
        )
    }

    /// Fresh per test: the row config is stored per server and the feed per identity, so nothing
    /// here may inherit or outlive another test's state.
    private func makeIdentity() -> CacheIdentity {
        CacheIdentity(serverID: "feed-\(UUID().uuidString)", userID: "u-\(UUID().uuidString)")
    }

    private func forget(_ identity: CacheIdentity) {
        FilterCache.shared.evict(identity: identity)
        UserDefaults.standard.removeObject(forKey: "homeRowConfigs.\(identity.serverID)")
    }

    @Test("a loaded feed is persisted and paints the next view model before any request")
    func feedSurvivesIntoTheNextViewModel() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let first = makeViewModel(service: FeedService(resumeItems: [item("m1")]), identity: identity)
        await first.loadContent()
        #expect(first.rows.contains { $0.type == .continueWatching })

        // A second view model on the same identity, before it is allowed to fetch anything.
        let second = makeViewModel(service: FeedService(resumeItems: []), identity: identity)
        #expect(second.rows.map(\.type) == [.continueWatching])
        #expect(second.rows.first?.items.map(\.id) == ["m1"])
        #expect(!second.isLoading, "a hydrated feed must not sit behind the spinner")
        #expect(second.isShowingCachedFeed)
    }

    @Test("a feed is never hydrated under another identity")
    func feedIsScopedToItsIdentity() async {
        let identity = makeIdentity()
        let neighbour = CacheIdentity(serverID: identity.serverID, userID: "other-\(UUID().uuidString)")
        defer { forget(identity); forget(neighbour) }

        let first = makeViewModel(service: FeedService(resumeItems: [item("m1")]), identity: identity)
        await first.loadContent()

        let otherProfile = makeViewModel(service: FeedService(resumeItems: []), identity: neighbour)
        #expect(otherProfile.rows.isEmpty)
        #expect(otherProfile.isLoading)
        #expect(!otherProfile.isShowingCachedFeed)
    }

    /// The trap the grid path documents: a load that answered nothing must not replace a good entry
    /// with an empty one.
    @Test("a failed load leaves the persisted feed alone")
    func failedLoadDoesNotOverwriteTheFeed() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let first = makeViewModel(service: FeedService(resumeItems: [item("m1")]), identity: identity)
        await first.loadContent()

        let offline = makeViewModel(service: FeedService(resumeItems: [], failsEverything: true), identity: identity)
        await offline.loadContent()

        let afterwards = makeViewModel(service: FeedService(resumeItems: []), identity: identity)
        #expect(afterwards.rows.first?.items.map(\.id) == ["m1"])
    }

    /// The interaction that makes the cache safe to ship: a shelf painted from disk is not a server
    /// that answered, so Home's own verdict has to survive it. Without this the first launch against
    /// an unreachable server would show last week's rows with every poster failing and no sentence
    /// saying why (Sodalite#122 renders that sentence).
    @Test("a cached feed does not silence the total-failure verdict")
    func cachedFeedDoesNotSilenceTheVerdict() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let first = makeViewModel(service: FeedService(resumeItems: [item("m1")]), identity: identity)
        await first.loadContent()

        let offline = makeViewModel(service: FeedService(resumeItems: [], failsEverything: true), identity: identity)
        #expect(offline.isShowingCachedFeed, "precondition: the second view model hydrated")
        await offline.loadContent()

        #expect(offline.loadFailedEntirely, "a hydrated feed hid the unreachable verdict")
        #expect(offline.isShowingCachedFeed, "nothing answered, so the feed is still the cached one")
    }

    /// A row the user has since disabled must not come back off disk, not even for the frame before
    /// loadContent prunes it.
    @Test("a row the stored config no longer plans is not hydrated")
    func disabledRowIsNotHydrated() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let first = makeViewModel(service: FeedService(resumeItems: [item("m1")]), identity: identity)
        await first.loadContent()
        #expect(first.rows.contains { $0.type == .continueWatching })

        var configs = HomeRowConfig.loadFromStorage(serverID: identity.serverID)
        for index in configs.indices where configs[index].type == .continueWatching {
            configs[index].isEnabled = false
        }
        HomeRowConfig.saveToStorage(configs, serverID: identity.serverID)

        let second = makeViewModel(service: FeedService(resumeItems: []), identity: identity)
        #expect(!second.rows.contains { $0.type == .continueWatching })
    }

    /// Change (3): the switch used to set `rows = []` and flip the spinner back on. It repaints from
    /// the destination's own entry instead, which is why it is safe to keep rows across a switch at
    /// all: the entry read here belongs to the identity being switched TO.
    @Test("a server switch repaints from the destination's feed instead of blanking")
    func serverSwitchDoesNotBlank() async {
        let identity = makeIdentity()
        defer { forget(identity) }

        let first = makeViewModel(service: FeedService(resumeItems: [item("m1")]), identity: identity)
        await first.loadContent()

        // The destination is unreachable, so nothing can repaint the shelf except the cache.
        let switched = makeViewModel(service: FeedService(resumeItems: [], failsEverything: true), identity: identity)
        await switched.reloadAfterServerSwitch()

        #expect(switched.rows.first?.items.map(\.id) == ["m1"], "the switch blanked a cached feed")
    }

    /// The uniqueness guarantee is the row's, not the writer's, so it has to hold on the way back in
    /// from disk as well.
    @Test("a decoded row still carries unique item ids")
    func decodingKeepsRowIdentityUnique() throws {
        let row = HomeRowData(type: .continueWatching, items: [item("a"), item("b")])
        var doubled = row
        doubled.items = [item("a"), item("a"), item("b")]

        let data = try JSONEncoder().encode(doubled)
        let decoded = try JSONDecoder().decode(HomeRowData.self, from: data)

        #expect(decoded.items.map(\.id) == ["a", "b"])
    }
}

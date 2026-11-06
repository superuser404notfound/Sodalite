import Testing
import Foundation
@testable import Sodalite

/// The Latest Movies row asks each movies library, not the global aggregate (Sodalite#231).
///
/// Without a `ParentId`, Jellyfin 12 scans the newest `Limit * 2` items across every library and
/// only then applies `IncludeItemTypes=Movie`. On a server whose recent additions are all episodes
/// that window holds no movie, and the row vanished although the Movies library was full.
@MainActor
struct HomeLatestMoviesRowTests {

    final class RecordingService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        struct LatestCall: Sendable, Equatable {
            let parentID: String?
            let includeItemTypes: [ItemType]?
        }

        private let lock = NSLock()
        private var calls: [LatestCall] = []
        var latestCalls: [LatestCall] { lock.withLock { calls } }

        var librariesDelay: Duration = .milliseconds(150)
        var libraries: [JellyfinLibrary] = []
        /// What a ParentId-scoped query answers, per library id.
        var latestByLibrary: [String: [JellyfinItem]] = [:]
        /// What the unscoped aggregate answers.
        var aggregate: [JellyfinItem] = []

        struct Unused: Error {}

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            try? await Task.sleep(for: librariesDelay)
            return libraries
        }

        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            lock.withLock { calls.append(LatestCall(parentID: parentID, includeItemTypes: includeItemTypes)) }
            guard includeItemTypes == [.movie] else { return [] }
            guard let parentID else { return aggregate }
            return latestByLibrary[parentID] ?? []
        }

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private static func movie(_ id: String, added: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","DateCreated":"\#(added)"}"#.utf8)
        )
    }

    private static func library(_ id: String, _ type: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: type, imageTags: nil)
    }

    /// A saved layout, so the aggregated row stays on: a fresh install with two movies libraries
    /// applies the split default and switches it off in favour of the per-library rows.
    private func makeViewModel(service: RecordingService) -> (HomeViewModel, String) {
        let serverID = "latestmovies-\(UUID().uuidString)"
        HomeRowConfig.saveToStorage(HomeRowConfig.defaultConfig(), scope: Self.scope(serverID))
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: serverID
        )
        return (vm, serverID)
    }

    private static func scope(_ serverID: String) -> String {
        ProfileKey(serverID: serverID, userID: "u1").storageScope
    }

    private func forget(serverID: String) {
        UserDefaults.standard.removeObject(forKey: "homeRowConfigs.\(Self.scope(serverID))")
    }

    @Test("the movies row asks the movies library even when the aggregate answers nothing")
    func moviesRowScopesToTheLibrary() async throws {
        let service = RecordingService()
        service.libraries = [Self.library("lib-movies", "movies"), Self.library("lib-tv", "tvshows")]
        service.latestByLibrary["lib-movies"] = [try Self.movie("m1", added: "2026-11-01T10:00:00Z")]
        service.aggregate = []
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let row = vm.rows.first { $0.type == .latestMovies }
        #expect(row?.items.map(\.id) == ["m1"], "the row did not show the library's movies: \(service.latestCalls)")
        #expect(!service.latestCalls.contains { $0.parentID == nil && $0.includeItemTypes == [.movie] },
                "the row still asked the unscoped aggregate: \(service.latestCalls)")
    }

    @Test("two movies libraries merge newest first")
    func twoLibrariesMergeByDateAdded() async throws {
        let service = RecordingService()
        service.libraries = [Self.library("lib-a", "movies"), Self.library("lib-b", "movies")]
        service.latestByLibrary["lib-a"] = [
            try Self.movie("a-new", added: "2026-11-03T10:00:00Z"),
            try Self.movie("a-old", added: "2026-10-01T10:00:00Z"),
        ]
        service.latestByLibrary["lib-b"] = [try Self.movie("b-mid", added: "2026-10-20T10:00:00Z")]
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let row = vm.rows.first { $0.type == .latestMovies }
        #expect(row?.items.map(\.id) == ["a-new", "b-mid", "a-old"])
    }

    @Test("a server with no movies library keeps the aggregate fallback")
    func noMoviesLibraryKeepsTheAggregate() async throws {
        let service = RecordingService()
        service.libraries = []
        service.aggregate = [try Self.movie("agg", added: "2026-11-01T10:00:00Z")]
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let row = vm.rows.first { $0.type == .latestMovies }
        #expect(row?.items.map(\.id) == ["agg"])
    }
}

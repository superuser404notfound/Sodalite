import Foundation
import Testing
@testable import Sodalite

@Suite(.serialized)
@MainActor
struct CombinedHomeFanOutTests {
    final class FakeLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var latest: [JellyfinItem] = []
        var libraries: [JellyfinLibrary] = []
        var delay: Duration = .zero
        var fail: Error?
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            if delay > .zero { try await Task.sleep(for: delay) }
            if let fail { throw fail }
            return latest
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            if let fail { throw fail }
            return libraries
        }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func movie(_ id: String, server: String, created: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","ServerId":"\#(server)","DateCreated":"\#(created)"}"#.utf8))
    }

    private let latestMovies = HomeRowConfig(type: .latestMovies, isEnabled: true, sortOrder: 0)

    private func model(_ a: FakeLibrary, _ b: FakeLibrary) -> HomeViewModel {
        let suffix = UUID().uuidString
        let sources = [
            HomeSource(serverID: "srv-a-\(suffix)", serverName: "A", userID: "u-a", libraryService: a, isActive: true),
            HomeSource(serverID: "srv-b-\(suffix)", serverName: "B", userID: "u-b", libraryService: b, isActive: false),
        ]
        let vm = HomeViewModel(
            libraryService: a,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u-a", serverID: sources[0].serverID, sources: sources)
        vm.secondaryDeadline = .milliseconds(200)
        return vm
    }

    @Test func bothServersLandInOneRow() async throws {
        let a = FakeLibrary(); a.latest = [try movie("a1", server: "a", created: "2026-01-01T00:00:00Z")]
        let b = FakeLibrary(); b.latest = [try movie("b1", server: "b", created: "2026-09-01T00:00:00Z")]
        let vm = model(a, b)
        let lists = await vm.fetchAcrossSources(latestMovies)
        #expect(lists.count == 2)
        guard case .media(let row) = await vm.fetch(.init(config: latestMovies, isTag: false, type: .latestMovies, id: latestMovies.id)) else {
            Issue.record("expected a media row"); return
        }
        #expect(row.items.map(\.id) == ["b1", "a1"])
    }

    @Test func slowSecondaryMissesTheDeadline() async throws {
        let a = FakeLibrary(); a.latest = [try movie("a1", server: "a", created: "2026-01-01T00:00:00Z")]
        let b = FakeLibrary(); b.delay = .seconds(5)
        let vm = model(a, b)
        let clock = ContinuousClock()
        let start = clock.now
        let lists = await vm.fetchAcrossSources(latestMovies)
        #expect(clock.now - start < .seconds(2))
        #expect(lists.count == 1)
        #expect(vm.pendingUnreachable == ["B"])
    }

    @Test func failedSecondaryIsReportedUnreachable() async throws {
        let a = FakeLibrary(); a.latest = [try movie("a1", server: "a", created: "2026-01-01T00:00:00Z")]
        let b = FakeLibrary(); b.fail = URLError(.cannotConnectToHost)
        let vm = model(a, b)
        _ = await vm.fetchAcrossSources(latestMovies)
        #expect(vm.pendingUnreachable == ["B"])
    }

    @Test func unauthorizedSecondaryIsMuted() async throws {
        let a = FakeLibrary()
        let b = FakeLibrary(); b.fail = APIError.unauthorized(message: nil)
        let vm = model(a, b)
        var muted: [String] = []
        vm.onUnauthorized = { muted.append($0) }
        _ = await vm.fetchAcrossSources(latestMovies)
        #expect(muted == [vm.sources[1].serverID])
        #expect(vm.pendingUnreachable.isEmpty)
    }

    @Test func feedIdentityDependsOnTheParticipants() {
        let a = FakeLibrary(), b = FakeLibrary()
        let combined = model(a, b)
        let single = HomeViewModel(
            libraryService: a,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u-a", serverID: combined.sources[0].serverID)
        #expect(combined.feedIdentity != single.feedIdentity)
        #expect(single.feedIdentity == single.cacheIdentity)
        #expect(combined.feedIdentity.serverID.hasPrefix("combined-"))
        #expect(HomeViewModel.combinedIdentity(for: combined.sources.reversed(), userID: "u-a") == combined.feedIdentity)
    }

    @Test func librariesFromBothServersAreStampedAndActiveFirst() async throws {
        let a = FakeLibrary(); a.libraries = [JellyfinLibrary(id: "la", name: "Movies", collectionType: "movies", imageTags: nil)]
        let b = FakeLibrary(); b.libraries = [JellyfinLibrary(id: "lb", name: "Movies", collectionType: "movies", imageTags: nil)]
        let vm = model(a, b)
        await vm.loadContent()
        #expect(vm.myMediaLibraries.map(\.id) == ["la", "lb"])
        #expect(vm.myMediaLibraries.map(\.serverID) == [vm.sources[0].serverID, vm.sources[1].serverID])
    }
}

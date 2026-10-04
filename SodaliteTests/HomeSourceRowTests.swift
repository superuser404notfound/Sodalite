import Foundation
import Testing
@testable import Sodalite

@MainActor
struct HomeSourceRowTests {
    final class RecordingLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var userIDs: [String] = []
        var latest: [JellyfinItem] = []
        var fail: Error?
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            userIDs.append(userID)
            if let fail { throw fail }
            return latest
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func model(active: RecordingLibrary) -> HomeViewModel {
        HomeViewModel(
            libraryService: active,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u-a", serverID: "srv-a-\(UUID().uuidString)")
    }

    @Test func aRowLoadsThroughTheGivenSourceAndItsUser() async throws {
        let active = RecordingLibrary()
        let other = RecordingLibrary()
        let vm = model(active: active)
        let source = HomeSource(serverID: "srv-b", serverName: "B", userID: "u-b", libraryService: other, isActive: false)
        _ = try await vm.loadRow(config: HomeRowConfig(type: .latestMovies, isEnabled: true, sortOrder: 0), source: source)
        #expect(other.userIDs == ["u-b"])
        #expect(active.userIDs.isEmpty)
    }

    @Test func theThrowingVariantSurfacesTheError() async {
        let other = RecordingLibrary()
        other.fail = APIError.unauthorized(message: nil)
        let vm = model(active: RecordingLibrary())
        let source = HomeSource(serverID: "srv-b", serverName: "B", userID: "u-b", libraryService: other, isActive: false)
        await #expect(throws: APIError.self) {
            _ = try await vm.loadRow(config: HomeRowConfig(type: .latestMovies, isEnabled: true, sortOrder: 0), source: source)
        }
    }

    @Test func theOldEntryPointStillUsesTheActiveServer() async {
        let active = RecordingLibrary()
        let vm = model(active: active)
        _ = await vm.loadRow(config: HomeRowConfig(type: .latestMovies, isEnabled: true, sortOrder: 0))
        #expect(active.userIDs == ["u-a"])
        #expect(vm.sources.count == 1)
    }
}

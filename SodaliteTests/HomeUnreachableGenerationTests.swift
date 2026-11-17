import Foundation
import Testing
@testable import Sodalite

/// BRW-205: a superseded load's secondary timeouts must not show up in the next load's notice.
@MainActor
struct HomeUnreachableGenerationTests {
    final class Library: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _slow: Bool
        init(slow: Bool) { _slow = slow }
        var slow: Bool {
            get { lock.withLock { _slow } }
            set { lock.withLock { _slow = newValue } }
        }

        private func pause() async { if slow { try? await Task.sleep(for: .seconds(2)) } }
        private var empty: JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { await pause(); return empty }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { await pause(); return empty }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { await pause(); return empty }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { await pause(); return [] }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { await pause(); return [] }
        func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    @Test func anOldLoadsTimeoutsDoNotReachTheNextLoad() async throws {
        let active = Library(slow: false)
        let secondary = Library(slow: true)
        let sources = [
            HomeSource(serverID: "a", serverName: "Wohnzimmer", userID: "u", libraryService: active, isActive: true),
            HomeSource(serverID: "b", serverName: "Keller", userID: "u", libraryService: secondary, isActive: false),
        ]
        let vm = HomeViewModel(
            libraryService: active,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u", serverID: "a-\(UUID().uuidString)", sources: sources)
        vm.secondaryDeadline = .milliseconds(300)

        let first = Task { await vm.loadContent() }
        try await Task.sleep(for: .milliseconds(80))
        secondary.slow = false
        await vm.loadContent()
        await first.value
        try await Task.sleep(for: .milliseconds(500))

        #expect(vm.pendingUnreachable.isEmpty)
        #expect(vm.unreachableServerNames.isEmpty)
    }
}

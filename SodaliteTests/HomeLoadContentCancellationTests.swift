import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 BROWSE-2. `withTaskGroup` does not cancel its remaining children when the body
/// returns early, it only awaits them; the stale-generation guard's `return` used to drop a
/// superseded load's results while every one of its still-outstanding row fetches ran to completion
/// on the shared limiter, right next to the load that replaced it.
@MainActor
struct HomeLoadContentCancellationTests {

    /// `getLibraries` fails fast (no reconciliation branch to reason about), `getResumeItems`
    /// resolves quickly so the superseded generation's for-loop reaches the stale guard while
    /// `getLatestMedia` is still sleeping, which is the one call this test watches.
    final class SlowRowService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _latestMediaOutcomes: [String] = []
        var latestMediaOutcomes: [String] { lock.withLock { _latestMediaOutcomes } }

        struct Unused: Error {}

        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            try await Task.sleep(for: .milliseconds(150))
            return JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }

        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                lock.withLock { _latestMediaOutcomes.append("cancelled") }
                throw error
            }
            lock.withLock { _latestMediaOutcomes.append("completed") }
            return []
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { throw Unused() }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Unused() }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw Unused() }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    private func makeViewModel(service: SlowRowService) -> (HomeViewModel, String) {
        let serverID = "cancel-\(UUID().uuidString)"
        HomeRowConfig.setMergeContinueWatchingNextUp(
            false, scope: ProfileKey(serverID: serverID, userID: "u1").storageScope
        )
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: serverID
        )
        vm.rowConfigs = [
            HomeRowConfig(type: .continueWatching, isEnabled: true, sortOrder: 0),
            HomeRowConfig(type: .latestMovies, isEnabled: true, sortOrder: 1)
        ]
        return (vm, serverID)
    }

    private func forget(serverID: String) {
        UserDefaults.standard.removeObject(forKey: "homeRowConfigs.\(serverID)")
        UserDefaults.standard.removeObject(forKey: "homeMergeCWNextUp.\(serverID)")
    }

    @Test("a superseded loadContent cancels its still-running row fetches instead of letting them finish")
    func supersededLoadCancelsSlowRowFetch() async {
        let service = SlowRowService()
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        let firstLoad = Task { await vm.loadContent() }
        // Let the first generation's row fetches start (and its fast resume call resolve) before
        // superseding it while the slow latestMovies call is still in flight.
        try? await Task.sleep(for: .milliseconds(70))
        await vm.loadContent()
        _ = await firstLoad.value

        #expect(
            service.latestMediaOutcomes.first == "cancelled",
            "the superseded generation's slow row fetch ran to completion: \(service.latestMediaOutcomes)"
        )
        #expect(
            service.latestMediaOutcomes.count == 2,
            "expected one cancelled call (superseded) and one completed call (the replacement): \(service.latestMediaOutcomes)"
        )
    }
}

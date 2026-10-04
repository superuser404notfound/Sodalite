import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 NETWORK-5. The series-sampling chain in `PosterBadgeStore` had no
/// `Task.isCancelled` check in its loop, and `enqueueSample`'s unstructured chain task neither
/// inherited the caller's cancellation nor returned early on it. Cancelling the enclosing
/// `.task(id:)` (scroll away, profile switch, the setting turned off) used to leave the whole
/// remaining chain enqueuing and running against the shared limiter.
@MainActor
struct PosterBadgeStoreCancellationTests {

    /// Only the series-sample shape (`parentID` set) carries behaviour; `enrich` never batches
    /// series items through the plain `ids:` query.
    final class SlowSeriesService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        private var _cancelledSeries: Set<String> = []
        var cancelledSeries: Set<String> { lock.withLock { _cancelledSeries } }

        struct Unused: Error {}

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            guard let seriesID = query.parentID else { throw Unused() }
            lock.withLock { _calls.append(seriesID) }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                lock.withLock { _cancelledSeries.insert(seriesID) }
                throw error
            }
            return JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { throw Unused() }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw Unused() }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    @Test("cancelling enrich stops the series chain instead of running every sample to completion")
    func cancellingStopsTheSeriesChain() async {
        let service = SlowSeriesService()
        let store = PosterBadgeStore(route: { _ in (service, "u1") }, isEnabled: { true })
        let seriesItems = (1...4).map { JellyfinItem(seriesStub: "s\($0)", name: "s\($0)") }

        let task = Task { await store.enrich(userID: "u1", seriesItems) }
        // Let the first sample start (and the chain begin) before cancelling mid-flight.
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await task.value

        #expect(
            service.calls == ["s1"],
            "cancellation did not stop enqueueing further series samples: \(service.calls)"
        )
        #expect(
            service.cancelledSeries.contains("s1"),
            "the in-flight sample ran to completion instead of observing cancellation"
        )
    }
}

import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 BROWSE-4. A `Task.detached` resolve doesn't inherit its parent's cancellation on
/// its own: cancelling `genreCachesTask` (or `providerCountsTask`) used to leave the detached resolve
/// running to completion, so a Home reappearing mid-precompute paid for both the orphaned pass and a
/// fresh one.
@MainActor
struct HomePrecomputeCancellationTests {

    /// Each call sleeps long enough that a real network round trip could never beat a cancellation
    /// requested a moment after it starts; it records whether it was cancelled or ran to completion.
    final class SlowGenreService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcomes: [String] = []
        private var _started = 0
        var outcomes: [String] { lock.withLock { _outcomes } }
        var started: Int { lock.withLock { _started } }

        struct Unused: Error {}

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            let name = query.genres?.first ?? "?"
            lock.withLock { _started += 1 }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                lock.withLock { _outcomes.append("cancelled:\(name)") }
                throw error
            }
            lock.withLock { _outcomes.append("completed:\(name)") }
            return JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { throw Unused() }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw Unused() }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func tag(_ name: String) -> TagCardData {
        TagCardData(id: name, name: name, backdropURL: nil)
    }

    @Test("cancelling the genre precompute stops its detached resolve instead of letting it run to completion")
    func cancellingGenrePrecomputeStopsTheDetachedResolve() async {
        let service = SlowGenreService()
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: "precompute-\(UUID().uuidString)"
        )
        // Five names against a maxConcurrent of 4: one is enqueued only after an earlier one
        // returns, which also exercises the "does a late enqueue after cancellation still take the
        // full delay" path.
        vm.tagRows = [
            HomeTagRowData(type: .genres, tags: [
                tag("Action"), tag("Comedy"), tag("Drama"), tag("Horror"), tag("Fantasy")
            ])
        ]

        let task = Task { await vm.precomputeGenreCaches() }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = await task.value

        #expect(
            service.outcomes.allSatisfy { $0.hasPrefix("cancelled") },
            "a cancelled precompute let its detached resolve run to completion: \(service.outcomes)"
        )
        #expect(vm.genreCachesComputedAt == nil, "a cancelled precompute latched as if it had finished")
    }

    /// Sodalite#169. A profile switch drops the view model, and its deinit is what cancels the passes.
    /// A pass that kept the view model alive for its own duration postponed exactly that deinit, so it
    /// ran to completion under the next profile's token (403s on the previous user's id) and wrote what
    /// it had left into the previous profile's FilterCache.
    @Test("dropping the view model mid-pass releases it and stops the resolve")
    func droppingTheViewModelMidPassStopsTheResolve() async {
        let service = SlowGenreService()
        weak var released: HomeViewModel?
        var vm: HomeViewModel? = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: "precompute-\(UUID().uuidString)"
        )
        vm?.tagRows = [
            HomeTagRowData(type: .genres, tags: [
                tag("Action"), tag("Comedy"), tag("Drama"), tag("Horror"), tag("Fantasy")
            ])
        ]
        vm?.scheduleGenreCaches(after: .zero)
        released = vm

        // Let go only once the pass is provably in flight, the moment a profile switch drops it.
        let started = ContinuousClock.now + .seconds(2)
        while service.started == 0, ContinuousClock.now < started {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.started > 0, "the pass never started, so this test measured nothing")
        vm = nil
        try? await Task.sleep(for: .milliseconds(30))
        #expect(released == nil, "the pass kept the view model alive after its view let go of it")

        let deadline = ContinuousClock.now + .seconds(2)
        while service.outcomes.count < 4, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            !service.outcomes.isEmpty && service.outcomes.allSatisfy { $0.hasPrefix("cancelled") },
            "the pass ran on after its view model was dropped: \(service.outcomes)"
        )
    }
}

import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 DIAG-4. `loadStats()` swallows `CancellationError` and leaves `stats` and
/// `errorMessage` both nil ("leave state as-is"). WatchStatsView used to gate loading on
/// `viewModel == nil`, a one-shot guard, so a cancel mid-scan (tvOS keeps the view's @State alive
/// across a tab switch but still cancels and re-fires `.task`) stuck the spinner forever: the
/// guard never let a second `loadStats()` run on the surviving view model.
@MainActor
struct WatchStatsCancelRecoveryTests {

    final class SlowStatsService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var delay: Duration = .milliseconds(200)

        struct Unused: Error {}

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            return JellyfinItemsResponse(items: [], totalRecordCount: 0)
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { throw Unused() }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw Unused() }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    @Test("a cancel mid-scan leaves stats and errorMessage nil, and a rerun on the same view model recovers")
    func cancelMidScanThenRerunRecovers() async {
        let service = SlowStatsService()
        service.delay = .milliseconds(200)
        let vm = WatchStatsViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1"
        )

        let task = Task { await vm.loadStats() }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await task.value

        #expect(vm.stats == nil, "a cancelled scan should leave stats untouched, not a partial result")
        #expect(vm.errorMessage == nil, "a cancellation must not surface as a user-facing error")

        // WatchStatsView's fix reruns loadStats() on the SAME view model whenever stats and
        // errorMessage are both nil; pin that the view model supports being rerun cleanly.
        service.delay = .zero
        await vm.loadStats()

        #expect(vm.stats != nil, "a rerun on the same view model did not recover from the earlier cancel")
    }
}

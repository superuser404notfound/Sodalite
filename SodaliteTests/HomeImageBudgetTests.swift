import Testing
import Foundation
@testable import Sodalite

/// Sodalite#212: Home asked `ImageCache` to hold several times its budget, so the prefetch of the
/// lower rows evicted the cards on screen and scrolling back up reloaded them from the server.
struct HomeImageBudgetTests {

    private let gib: UInt64 = 1 << 30

    @Test func budgetScalesWithTheDevicesMemory() {
        #expect(ImageCache.costLimit(physicalMemory: 2 * gib) == 150_000_000)
        #expect(ImageCache.costLimit(physicalMemory: 3 * gib) == 225_000_000)
        #expect(ImageCache.costLimit(physicalMemory: 4 * gib) == 300_000_000)
    }

    /// A device reports a little under its nominal size; that must not drop it a tier.
    @Test func budgetRoundsTheReportedMemoryToTheNominalSize() {
        #expect(ImageCache.costLimit(physicalMemory: 4 * gib - 180_000_000) == 300_000_000)
    }

    @Test func budgetIsClampedAtBothEnds() {
        #expect(ImageCache.costLimit(physicalMemory: 1 * gib) == 150_000_000)
        #expect(ImageCache.costLimit(physicalMemory: 16 * gib) == 300_000_000)
    }

    /// Half the budget, in typical cards, so a prefetch can never push the visible rows out.
    @Test func prefetchLimitLeavesHalfTheBudgetToTheScreen() {
        #expect(ImageCache.prefetchLimit(costLimit: 300_000_000) == 60)
        #expect(ImageCache.prefetchLimit(costLimit: 150_000_000) == 30)
    }

    private func urls(_ row: Int, _ count: Int) -> [URL] {
        (0..<count).map { URL(string: "https://s/r\(row)/\($0)")! }
    }

    @Test func planTakesTheHeadOfEveryRowInRowOrder() {
        let plan = HomePrefetchPlan.urls(rows: [urls(0, 20), urls(1, 3), urls(2, 20)], perRow: 4, limit: 100)
        #expect(plan == Array(urls(0, 4)) + urls(1, 3) + Array(urls(2, 4)))
    }

    @Test func planStopsAtTheLimitWithTheTopRowsFirst() {
        let plan = HomePrefetchPlan.urls(rows: [urls(0, 20), urls(1, 20), urls(2, 20)], perRow: 8, limit: 10)
        #expect(plan == Array(urls(0, 8)) + Array(urls(1, 2)))
    }

    /// One picture in two rows (Continue Watching and Latest) is one cache entry and one slot.
    @Test func planCountsADuplicateOnce() {
        let shared = URL(string: "https://s/shared")!
        let plan = HomePrefetchPlan.urls(rows: [[shared] + urls(0, 2), [shared] + urls(1, 2)], perRow: 3, limit: 100)
        #expect(plan == [shared] + urls(0, 2) + urls(1, 2))
    }
}

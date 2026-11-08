import Testing
@testable import Sodalite

/// Sodalite#212: the image cache has to keep what was drawn LAST, so scrolling back over rows just
/// seen does not reload them.
struct LRUCostCacheTests {

    @Test func evictsTheLeastRecentlyUsedEntryFirst() {
        let cache = LRUCostCache<String, Int>(costLimit: 3)
        cache.store(1, for: "a", cost: 1)
        cache.store(2, for: "b", cost: 1)
        cache.store(3, for: "c", cost: 1)
        #expect(cache.value(for: "a") == 1)
        cache.store(4, for: "d", cost: 1)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.value(for: "d") == 4)
        #expect(cache.takeEvictionCount() == 1)
        #expect(cache.takeEvictionCount() == 0)
    }

    @Test func evictsByCostNotByCount() {
        let cache = LRUCostCache<String, Int>(costLimit: 10)
        cache.store(1, for: "a", cost: 4)
        cache.store(2, for: "b", cost: 4)
        cache.store(3, for: "c", cost: 6)
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == 2)
        #expect(cache.totalCost == 10)
        cache.store(4, for: "d", cost: 7)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == nil)
        #expect(cache.totalCost == 7)
    }

    @Test func replacingAnEntryUpdatesItsCost() {
        let cache = LRUCostCache<String, Int>(costLimit: 10)
        cache.store(1, for: "a", cost: 8)
        cache.store(2, for: "a", cost: 2)
        cache.store(3, for: "b", cost: 8)
        #expect(cache.value(for: "a") == 2)
        #expect(cache.totalCost == 10)
        #expect(cache.count == 2)
    }

    @Test func anEntryOverTheWholeBudgetIsNotStoredAndEvictsNothing() {
        let cache = LRUCostCache<String, Int>(costLimit: 10)
        cache.store(1, for: "a", cost: 5)
        cache.store(2, for: "huge", cost: 11)
        #expect(cache.value(for: "huge") == nil)
        #expect(cache.value(for: "a") == 1)
    }

    @Test func trimKeepsTheNewestEntries() {
        let cache = LRUCostCache<String, Int>(costLimit: 4)
        for (i, key) in ["a", "b", "c", "d"].enumerated() { cache.store(i, for: key, cost: 1) }
        cache.trim(toFraction: 0.5)
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == 2)
        #expect(cache.value(for: "d") == 3)
    }

    @Test func removeAllEmptiesWithoutCountingEvictions() {
        let cache = LRUCostCache<String, Int>(costLimit: 4)
        cache.store(1, for: "a", cost: 1)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        #expect(cache.takeEvictionCount() == 0)
        cache.store(2, for: "b", cost: 1)
        #expect(cache.value(for: "b") == 2)
    }
}

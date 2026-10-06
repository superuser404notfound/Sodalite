import Foundation
import Testing
@testable import Sodalite

@MainActor
struct AlphabetJumpResolverTests {
    @MainActor final class Counter {
        var queries: [ItemQuery] = []
        var answer = 42
        var fails = false
        func count(_ query: ItemQuery) async throws -> Int {
            queries.append(query)
            if fails { throw URLError(.timedOut) }
            return answer
        }
    }

    private let base = ItemQuery(parentID: "lib", sortBy: "SortName", sortOrder: "Ascending", limit: 200, fields: "")

    @Test func resolverCachesPerLetter() async {
        let counter = Counter()
        let resolver = AlphabetJumpResolver(count: { try await counter.count($0) })
        #expect(await resolver.slot(for: "P", base: base, descending: false) == 42)
        #expect(await resolver.slot(for: "P", base: base, descending: false) == 42)
        #expect(counter.queries.count == 1)
        resolver.reset()
        _ = await resolver.slot(for: "P", base: base, descending: false)
        #expect(counter.queries.count == 2)
    }

    @Test func hashAscendingIsZeroWithoutRequest() async {
        let counter = Counter()
        let resolver = AlphabetJumpResolver(count: { try await counter.count($0) })
        #expect(await resolver.slot(for: "#", base: base, descending: false) == 0)
        #expect(counter.queries.isEmpty)
    }

    @Test func failureIsNilAndNotCached() async {
        let counter = Counter()
        counter.fails = true
        let resolver = AlphabetJumpResolver(count: { try await counter.count($0) })
        #expect(await resolver.slot(for: "P", base: base, descending: false) == nil)
        counter.fails = false
        #expect(await resolver.slot(for: "P", base: base, descending: false) == 42)
    }

    @Test func resolverDropsCancelledResult() async {
        let counter = Counter()
        let resolver = AlphabetJumpResolver(count: { try await counter.count($0) })
        let task = Task { await resolver.slot(for: "P", base: base, descending: false) }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test func cachedSlotAnswersWithoutARequest() async {
        let counter = Counter()
        let resolver = AlphabetJumpResolver(count: { try await counter.count($0) })
        #expect(resolver.cachedSlot(for: "P", descending: false) == nil)
        #expect(resolver.cachedSlot(for: "#", descending: false) == 0)
        _ = await resolver.slot(for: "P", base: base, descending: false)
        #expect(resolver.cachedSlot(for: "P", descending: false) == 42)
        #expect(resolver.cachedSlot(for: "P", descending: true) == nil)
    }
}

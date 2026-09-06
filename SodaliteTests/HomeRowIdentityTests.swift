import Testing
@testable import Sodalite

/// A home row renders through `ForEach(items)`, so two items claiming one id is not a cosmetic
/// duplicate: SwiftUI's layout for it is undefined, and on device the second one reserved its slot
/// in the LazyHStack and drew nothing at all, no artwork and no title. Latest Series produces the
/// repeat by construction, one Latest query per library round-robined together, so a series that
/// lives in two libraries arrives twice.
struct HomeRowIdentityTests {

    private func series(_ id: String, _ name: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: name)
    }

    @Test func aRepeatedItemIsCollapsed() {
        let row = HomeRowData(type: .latestShows, items: [
            series("a", "Der kleine Tiger Daniel"),
            series("b", "Die Discounter"),
            series("b", "Die Discounter"),
            series("c", "The Walking Dead"),
            series("c", "The Walking Dead"),
            series("d", "Cyberpunk: Edgerunners"),
        ])

        #expect(row.items.map(\.id) == ["a", "b", "c", "d"])
    }

    /// First occurrence wins, so the round-robin's recency ordering survives: the merge puts the
    /// earliest sighting of a series where its newest library placed it.
    @Test func theFirstSightingIsTheOneThatStays() {
        let row = HomeRowData(type: .latestShows, items: [
            series("a", "from the first library"),
            series("b", "another"),
            series("a", "from the second library"),
        ])

        #expect(row.items.count == 2)
        #expect(row.items.first?.name == "from the first library")
    }

    /// The uniqueness is a property of the type, not of the one row that exposed the defect.
    @Test func everyRowTypeGetsTheSameGuarantee() {
        for type in [HomeRowType.continueWatching, .latestMovies, .allSeries, .libraryLatest] {
            let row = HomeRowData(type: type, items: [series("x", "one"), series("x", "one")])
            #expect(row.items.count == 1, "\(type) kept a duplicate id")
        }
    }

    @Test func anAlreadyUniqueRowIsUntouched() {
        let items = [series("a", "a"), series("b", "b"), series("c", "c")]
        let row = HomeRowData(type: .latestShows, items: items)

        #expect(row.items.map(\.id) == ["a", "b", "c"])
    }
}

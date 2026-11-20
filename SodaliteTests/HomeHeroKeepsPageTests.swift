import Testing
import Foundation
@testable import Sodalite

/// Closing a detail page can refetch Home. In Favorites mode that reshuffled the banner, and any new
/// list sent it to its first page, so the viewer came back to another title with focus on its Play
/// button (measured on the Apple TV, 2026-11-14).
struct HomeHeroKeepsPageTests {

    private func item(_ id: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: id)
    }

    @Test func aReloadKeepsTheShownPicksInTheirOrder() {
        let shown = ["c", "a", "b"].map(item)
        let reshuffled = ["a", "b", "d", "c"].map(item)

        let picks = HomeViewModel.keepingPicks(shown, from: reshuffled, limit: 8)

        #expect(picks.map(\.id) == ["c", "a", "b", "d"])
    }

    @Test func aRemovedFavouriteDropsOutAndTheLimitHolds() {
        let shown = ["a", "b", "c"].map(item)
        let candidates = ["c", "x", "a", "y", "z"].map(item)

        let picks = HomeViewModel.keepingPicks(shown, from: candidates, limit: 3)

        #expect(picks.map(\.id) == ["a", "c", "x"])
    }

    @Test func theTitleOnScreenKeepsItsPage() {
        #expect(HomeHeroCarousel.pageKeepingTitle(onScreen: 2, of: ["a", "b", "c"], in: ["c", "a", "b"]) == 0)
        #expect(HomeHeroCarousel.pageKeepingTitle(onScreen: 0, of: ["a", "b", "c"], in: ["b", "c", "a"]) == 2)
    }

    @Test func aTitleThatLeftFallsBackToTheFirstPage() {
        #expect(HomeHeroCarousel.pageKeepingTitle(onScreen: 1, of: ["a", "b"], in: ["a", "c"]) == 0)
        #expect(HomeHeroCarousel.pageKeepingTitle(onScreen: 5, of: ["a"], in: ["a"]) == 0)
    }
}

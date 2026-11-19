import Testing
@testable import Sodalite

/// What each banner mode asks the server for. Recently Added showed titles the viewer had already
/// watched, which made the banner look stale (Sodalite#246).
struct HomeHeroQueryTests {

    @Test func recentlyAddedSkipsWatchedTitles() {
        let query = HomeViewModel.heroQuery(.recentlyAdded)
        #expect(query.filters == ["IsUnplayed"])
        #expect(query.sortBy == "DateCreated")
        #expect(query.sortOrder == "Descending")
    }

    @Test func discoverSkipsWatchedTitles() {
        #expect(HomeViewModel.heroQuery(.discover).filters == ["IsUnplayed"])
    }

    /// A favourite stays in the banner after it was watched, that is why it is a favourite.
    @Test func favoritesKeepWatchedTitles() {
        let query = HomeViewModel.heroQuery(.favorites)
        #expect(query.filters == nil || query.filters?.isEmpty == true)
        #expect(query.isFavorite == true)
    }
}

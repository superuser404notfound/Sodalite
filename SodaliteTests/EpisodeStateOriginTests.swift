import Testing
@testable import Sodalite

/// The series page swaps its header for an episode rather than pushing a screen, so Menu has to be
/// told whether there is anything behind that swap. Getting it wrong in either direction costs a
/// press: intercepting too eagerly puts a page the viewer never asked for between them and Home,
/// not intercepting at all throws away the show page they were reading.
struct EpisodeStateOriginTests {

    /// A page opened straight into the episode state, which is every Continue Watching card, every
    /// Next Up card, Search and Top Shelf. Menu leaves.
    @Test func aPageThatOpenedOnAnEpisodeHasNothingBehindIt() {
        #expect(!EpisodeStateOrigin().hasSeriesStateBehind)
    }

    @Test func openingAnEpisodeFromTheStripPutsTheSeriesBehindIt() {
        var origin = EpisodeStateOrigin()
        origin.openedFromSeries()
        #expect(origin.hasSeriesStateBehind)
    }

    /// The player auto-advancing counts only if the page was on the series state when it happened.
    @Test func theAdvanceCountsOnlyFromTheSeriesState() {
        var fromSeries = EpisodeStateOrigin()
        fromSeries.playerAdvanced(fromSeriesState: true)
        #expect(fromSeries.hasSeriesStateBehind)

        var fromEpisode = EpisodeStateOrigin()
        fromEpisode.playerAdvanced(fromSeriesState: false)
        #expect(!fromEpisode.hasSeriesStateBehind)
    }

    /// The reporter's case end to end: Continue Watching, watch, the player rolls into the next
    /// episode, Back. Still one press out, because nothing on this page was ever stepped into.
    @Test func continueWatchingThenAnAutoAdvanceIsStillOnePressOut() {
        var origin = EpisodeStateOrigin()
        origin.playerAdvanced(fromSeriesState: false)
        #expect(!origin.hasSeriesStateBehind)
    }

    @Test func goingBackToTheSeriesEmptiesItAgain() {
        var origin = EpisodeStateOrigin()
        origin.openedFromSeries()
        origin.returnedToSeries()
        #expect(!origin.hasSeriesStateBehind)
    }
}

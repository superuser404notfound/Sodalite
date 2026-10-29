import Foundation

/// Whether the series page has a series state BEHIND its episode state, which is what decides
/// whether Menu goes back one step or leaves the page (Sodalite#146).
///
/// A value type because the rule is not "is an episode showing". An episode opened from Continue
/// Watching, Next Up, Search or Top Shelf arrives with the page already in the episode state: that
/// is the ground state of the page, not a step taken on it. Intercepting Menu there put a series
/// page the viewer never asked for between them and Home, one press more than before (device,
/// 2026-09-14). Only a move made ON the page (the strip, the Show Episode button) puts a state
/// behind the current one, and there are three writers of `selectedEpisode` that are not such a
/// move (the opening deep link, an in-place item replacement, and the enrichment round trip), which
/// is exactly why this is named rather than left as an assignment next to each of them.
struct EpisodeStateOrigin: Equatable {
    /// False on a page that opened straight into the episode state.
    private(set) var hasSeriesStateBehind = false

    /// The viewer opened an episode from the series state: the strip, or the Show Episode button.
    mutating func openedFromSeries() {
        hasSeriesStateBehind = true
    }

    /// The player advanced to the next episode and the page followed. Only counts while the page was
    /// on the series state: an advance during an episode the viewer arrived on has not moved them
    /// anywhere they can go back to.
    mutating func playerAdvanced(fromSeriesState: Bool) {
        if fromSeriesState { hasSeriesStateBehind = true }
    }

    /// Back on the series state, so there is nothing behind it again.
    mutating func returnedToSeries() {
        hasSeriesStateBehind = false
    }
}

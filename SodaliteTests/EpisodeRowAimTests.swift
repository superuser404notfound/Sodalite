import Testing
@testable import Sodalite

/// The episode row on a series page has one memory of which card it should aim at, and three
/// entries read it: a move down from the season bar, the one-shot redirect that catches a focus
/// arriving from anywhere else, and the return from the player.
///
/// The case that made this a type: starting episode 10 from the row and letting the player advance
/// to episode 20 used to drop the viewer back on 10. The memory was written once, when focus left
/// the row on the way into the player, and nothing moved it while the session walked forward behind
/// the modal, so the entry resolver named the episode that was STARTED rather than the one that was
/// watched.
struct EpisodeRowAimTests {

    private let seasonOne = ["s1e1", "s1e2", "s1e3"]

    @Test("A fresh row with no next-up episode starts at the first card")
    func emptyMemoryStartsAtFirst() {
        let aim = EpisodeRowAim()
        #expect(aim.target(in: seasonOne, currentEpisodeID: nil) == "s1e1")
    }

    @Test("A fresh row prefers the series' current episode over the first card")
    func emptyMemoryPrefersCurrent() {
        let aim = EpisodeRowAim()
        #expect(aim.target(in: seasonOne, currentEpisodeID: "s1e3") == "s1e3")
    }

    @Test("An empty season aims at nothing")
    func emptySeasonAimsAtNothing() {
        var aim = EpisodeRowAim()
        aim.focusLeft("s1e2")
        #expect(aim.target(in: [], currentEpisodeID: "s1e2") == nil)
    }

    @Test("The row returns to the card the viewer left it on, not to the current episode")
    func memoryOutranksCurrentEpisode() {
        var aim = EpisodeRowAim()
        aim.focusLeft("s1e2")
        #expect(aim.target(in: seasonOne, currentEpisodeID: "s1e3") == "s1e2")
    }

    /// The season filter: a remembered id the loaded season does not hold is not an aim.
    @Test("A card from another season falls through to the current episode")
    func staleSeasonMemoryFallsThrough() {
        var aim = EpisodeRowAim()
        aim.focusLeft("s2e7")
        #expect(aim.target(in: seasonOne, currentEpisodeID: "s1e3") == "s1e3")
    }

    /// The reported defect: ten auto-advances between the card that was pressed and the card the
    /// session ended on.
    @Test("A session that ran from episode 1 to episode 3 returns to 3, not to 1")
    func sessionSwitchOutranksTheCardThePlayerWasStartedFrom() {
        var aim = EpisodeRowAim()
        aim.focusLeft("s1e1")          // focus leaves the row as the player takes over
        aim.sessionMoved(to: "s1e2")   // auto-advance, behind the modal
        aim.sessionMoved(to: "s1e3")
        #expect(aim.target(in: seasonOne, currentEpisodeID: "s1e1") == "s1e3")
    }

    /// Rolling into the next season is the same write; it aims once that season's row is the loaded
    /// one, and stays out of the way of the season the viewer is still looking at.
    @Test("A session that rolled into the next season aims there, not into the season on screen")
    func sessionSwitchAcrossSeasons() {
        var aim = EpisodeRowAim()
        aim.focusLeft("s1e3")
        aim.sessionMoved(to: "s2e1")
        #expect(aim.target(in: seasonOne, currentEpisodeID: "s1e3") == "s1e3")
        #expect(aim.target(in: ["s2e1", "s2e2"], currentEpisodeID: "s2e2") == "s2e1")
    }

    /// Leaving the row after the player closed is an ordinary write; the session's last word does
    /// not outlive the viewer's own move.
    @Test("A move made after the player closed replaces what the session left behind")
    func laterFocusMoveReplacesSessionMemory() {
        var aim = EpisodeRowAim()
        aim.sessionMoved(to: "s1e3")
        aim.focusLeft("s1e1")
        #expect(aim.target(in: seasonOne, currentEpisodeID: nil) == "s1e1")
    }
}

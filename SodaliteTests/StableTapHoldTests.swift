import Foundation
import Testing
@testable import Sodalite

/// A row that carries a `.contextMenu` answers two readings of the same press. The click used to be
/// decided ~10 ms in, so the row acted on the way into its own menu: on Settings > Servers an inactive
/// row switched servers instead of ever showing the menu the hint text promises (Sodalite#75).
@Suite("Click and hold on a row whose long press opens a menu")
struct StableTapHoldTests {
    @Test func aShortPressOnSteadyFocusIsAClick() {
        #expect(StableTapModifier.isClick(beganOnStableFocus: true, pressDuration: 0.05))
        #expect(StableTapModifier.isClick(beganOnStableFocus: true, pressDuration: 0.3))
    }

    /// The press that opens the menu must leave with nothing else done, or the hold is spent twice.
    @Test func aPressThatReachesTheMenusHoldIsNotAClick() {
        #expect(!StableTapModifier.isClick(
            beganOnStableFocus: true,
            pressDuration: StableTapModifier.clickHoldLimit
        ))
        #expect(!StableTapModifier.isClick(beganOnStableFocus: true, pressDuration: 1.2))
    }

    /// Stability is read when the press starts, so the drift guard survives the move to release: a hold
    /// long enough to look steady in hindsight still does not activate a row focus drifted onto.
    @Test func driftAtPressTimeStillLosesHoweverLongThePressRuns() {
        #expect(!StableTapModifier.isClick(beganOnStableFocus: false, pressDuration: 0.05))
        #expect(!StableTapModifier.isClick(beganOnStableFocus: false, pressDuration: 0.39))
    }

    /// The gesture's clock starts at the press, ours a frame later when the callback lands, so a hold that
    /// completed can measure just under the limit. Completion decides, not the stopwatch (Sodalite#175: a
    /// hold on a multiview tile sometimes opened it full screen instead of its menu).
    @Test func aHoldThatCompletedIsNeverAClickHoweverShortItMeasured() {
        #expect(!StableTapModifier.isClick(beganOnStableFocus: true, pressDuration: 0.39, holdReachedLimit: true))
        #expect(!StableTapModifier.isClick(beganOnStableFocus: true, pressDuration: 0.05, holdReachedLimit: true))
        #expect(StableTapModifier.isClick(beganOnStableFocus: true, pressDuration: 0.39, holdReachedLimit: false))
    }

    /// The limit has to stay under the ~0.5 s at which tvOS opens the menu, else the two readings
    /// overlap and a menu-opening press fires the row as well.
    @Test func theClickLimitStaysBelowTheMenusHold() {
        #expect(StableTapModifier.clickHoldLimit < 0.5)
        #expect(StableTapModifier.clickHoldLimit > StableTapModifier.stableFocusWindow)
    }
}

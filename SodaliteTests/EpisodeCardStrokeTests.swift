import Foundation
import Testing
@testable import Sodalite

/// The ring around an episode card. It used to carry three meanings (focused, selected, the series'
/// current episode), two of which always landed on the same card: the page resolves its play target
/// from the selected episode first, so "selected" and "what Play does" were the same answer drawn
/// twice, in two colours, at two widths. With the accent themes in the catalog the selected tint and
/// the focus role are also near neighbours, so the third ring was mostly invisible anyway.
///
/// Two meanings are left. Focus wins over the play target: a ring has to answer "you are here"
/// before it answers "this is where Play goes".
struct EpisodeCardStrokeTests {

    @Test("A card that is neither focused nor the play target draws no ring")
    func plainCard() {
        #expect(EpisodeCardStroke.role(isFocused: false, isPlayTarget: false) == .none)
        #expect(EpisodeCardStroke.none.lineWidth == 0)
    }

    @Test("The play target draws the thinner ring")
    func playTargetRing() {
        #expect(EpisodeCardStroke.role(isFocused: false, isPlayTarget: true) == .playTarget)
        #expect(EpisodeCardStroke.playTarget.lineWidth == 3)
    }

    @Test("Focus draws the thickest ring")
    func focusRing() {
        #expect(EpisodeCardStroke.role(isFocused: true, isPlayTarget: false) == .focused)
        #expect(EpisodeCardStroke.focused.lineWidth == 4)
    }

    @Test("Focus outranks the play target on the card that is both")
    func focusBeatsPlayTarget() {
        #expect(EpisodeCardStroke.role(isFocused: true, isPlayTarget: true) == .focused)
    }

    /// The guard against a third ring creeping back in: the card that Play acts on and the card the
    /// panel is showing are one card, and a separate "selected" ring would say so a second time.
    @Test("The card knows exactly three ring states")
    func vocabularyIsClosed() {
        #expect(EpisodeCardStroke.allCases.count == 3)
    }
}

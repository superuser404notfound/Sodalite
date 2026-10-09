import Testing
import Foundation
@testable import Sodalite

/// The per-title subtitle offset adjusted from the player's subtitle menu.
struct SubtitleOffsetTests {

    @Test("one step moves a tenth of a second either way")
    func singleSteps() {
        #expect(SubtitleOffset.stepped(0, by: 1) == 0.1)
        #expect(SubtitleOffset.stepped(0, by: -1) == -0.1)
    }

    /// Repeated Double addition drifts (0.1 + 0.2 != 0.3); the label and the stored value must not.
    @Test("many steps land on an exact tenth")
    func noDrift() {
        var value = 0.0
        for _ in 0..<7 { value = SubtitleOffset.stepped(value, by: 1) }
        #expect(value == 0.7)
    }

    @Test("the offset stops at ten seconds in both directions")
    func clamps() {
        #expect(SubtitleOffset.stepped(9.95, by: 1) == 10)
        #expect(SubtitleOffset.stepped(-10, by: -1) == -10)
    }
}

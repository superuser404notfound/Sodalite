import Testing
@testable import Sodalite

/// Sodalite#115 (second half of the report): every settings toggle in the app is a `ValuePickerRow`
/// over `[false, true]`, and the row's step used to clamp at both ends. The select click only ever
/// steps FORWARD, so a toggle already sitting on its last option had a click that did nothing at all:
/// "Stats for Nerds" and "Engine Diagnostics" could be switched on with a click and never off again.
/// A two-option row is a toggle and wraps; three or more stay a clamped ordered list, where the greyed
/// chevron at the end is an honest cue.
@Suite("Value picker row stepping")
struct ValuePickerRowAdvanceTests {

    @Test("a two-option row toggles in both directions, from either state")
    func twoOptionsWrap() {
        #expect(ValuePickerAdvance.index(from: 0, by: 1, count: 2) == 1)
        #expect(ValuePickerAdvance.index(from: 1, by: 1, count: 2) == 0)
        #expect(ValuePickerAdvance.index(from: 0, by: -1, count: 2) == 1)
        #expect(ValuePickerAdvance.index(from: 1, by: -1, count: 2) == 0)
    }

    @Test("a two-option row never reports a dead end, so neither chevron greys out")
    func twoOptionsAlwaysMovable() {
        for current in 0...1 {
            #expect(ValuePickerAdvance.canMove(from: current, by: 1, count: 2))
            #expect(ValuePickerAdvance.canMove(from: current, by: -1, count: 2))
        }
    }

    @Test("three or more options still clamp at both ends")
    func longerListsClamp() {
        #expect(ValuePickerAdvance.index(from: 1, by: 1, count: 4) == 2)
        #expect(ValuePickerAdvance.index(from: 3, by: 1, count: 4) == 3)
        #expect(ValuePickerAdvance.index(from: 0, by: -1, count: 4) == 0)
        #expect(ValuePickerAdvance.index(from: 0, by: 1, count: 3) == 1)
    }

    @Test("a clamped list reports its ends, which is what greys the chevrons")
    func longerListsReportEnds() {
        #expect(!ValuePickerAdvance.canMove(from: 0, by: -1, count: 4))
        #expect(!ValuePickerAdvance.canMove(from: 3, by: 1, count: 4))
        #expect(ValuePickerAdvance.canMove(from: 0, by: 1, count: 4))
        #expect(ValuePickerAdvance.canMove(from: 3, by: -1, count: 4))
    }

    @Test("degenerate lists stay in bounds instead of trapping")
    func degenerateLists() {
        #expect(ValuePickerAdvance.index(from: 0, by: 1, count: 1) == 0)
        #expect(ValuePickerAdvance.index(from: 0, by: -1, count: 1) == 0)
        #expect(ValuePickerAdvance.index(from: 0, by: 1, count: 0) == 0)
        #expect(!ValuePickerAdvance.canMove(from: 0, by: 1, count: 1))
    }
}

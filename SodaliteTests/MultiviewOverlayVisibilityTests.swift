import Foundation
import Testing
@testable import Sodalite

struct MultiviewOverlayVisibilityTests {
    @Test func focusMovingHidesThePreviousTile() {
        let a = UUID(), b = UUID()
        let t0 = ContinuousClock.now
        var v = MultiviewOverlayVisibility()
        v.focusChanged(to: a, now: t0)
        v.focusChanged(to: b, now: t0.advanced(by: .seconds(1)))
        #expect(!v.isVisible(a))
        #expect(v.isVisible(b))
    }

    @Test func audioOnTheFocusedTileExtendsTheHold() {
        let a = UUID()
        let t0 = ContinuousClock.now
        var v = MultiviewOverlayVisibility()
        v.focusChanged(to: a, now: t0)
        v.audioArrived(on: a, now: t0.advanced(by: .seconds(2)))
        v.expire(now: t0.advanced(by: .seconds(4)))
        #expect(v.isVisible(a))
        v.expire(now: t0.advanced(by: .seconds(5)))
        #expect(!v.isVisible(a))
    }

    @Test func aTriggerForAnUnfocusedTileShowsNothing() {
        let a = UUID(), b = UUID()
        let t0 = ContinuousClock.now
        var v = MultiviewOverlayVisibility()
        v.focusChanged(to: a, now: t0)
        v.audioArrived(on: b, now: t0)
        #expect(!v.isVisible(b))
        #expect(v.isVisible(a))
    }

    @Test func losingFocusAltogetherHidesEverything() {
        let a = UUID()
        var v = MultiviewOverlayVisibility()
        v.focusChanged(to: a, now: .now)
        v.focusChanged(to: nil, now: .now)
        #expect(!v.isVisible(a))
    }
}

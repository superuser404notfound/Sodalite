import Foundation
import Testing
@testable import Sodalite

struct MultiviewOverlayVisibilityTests {
    @Test func hidesAfterHoldFromLastTrigger() {
        let id = UUID()
        let t0 = ContinuousClock.now
        var v = MultiviewOverlayVisibility()
        v.show(id, now: t0)
        v.show(id, now: t0.advanced(by: .seconds(2)))
        v.expire(now: t0.advanced(by: .seconds(4)))
        #expect(v.isVisible(id))
        v.expire(now: t0.advanced(by: .seconds(5)))
        #expect(!v.isVisible(id))
    }

    @Test func tilesExpireIndependently() {
        let a = UUID(), b = UUID()
        let t0 = ContinuousClock.now
        var v = MultiviewOverlayVisibility()
        v.show(a, now: t0)
        v.show(b, now: t0.advanced(by: .seconds(1)))
        v.expire(now: t0.advanced(by: .seconds(3)))
        #expect(!v.isVisible(a) && v.isVisible(b))
        #expect(v.nextDeadline == t0.advanced(by: .seconds(4)))
    }
}

import Testing
import SwiftUI
@testable import Sodalite

/// Sodalite#259. The lean follows the thumb, but only from where the thumb was when the card took
/// focus, and only while that same touch lasts.
struct CardTiltTests {

    @Test func liftedThumbIsFlat() {
        let tilt = CardTilt.from(reading: RemoteTouchReading(x: 0, y: 0, touch: 3), origin: nil)
        #expect(tilt == .flat)
        #expect(tilt.sheenOpacity == 0)
    }

    @Test func swipeThatMovedFocusLandsFlat() {
        // The swipe that brought focus here still has the thumb far right.
        let arrival = RemoteTouchReading(x: 0.7, y: 0.1, touch: 5)
        #expect(CardTilt.from(reading: arrival, origin: arrival) == .flat)

        let later = RemoteTouchReading(x: 0.9, y: 0.1, touch: 5)
        let tilt = CardTilt.from(reading: later, origin: arrival)
        #expect(abs(tilt.x - 0.2) < 1e-9)
        #expect(tilt.y == 0)
    }

    @Test func originFromAnEarlierTouchIsIgnored() {
        let origin = RemoteTouchReading(x: 0.7, y: 0, touch: 5)
        let next = RemoteTouchReading(x: 0.3, y: -0.4, touch: 6)
        let tilt = CardTilt.from(reading: next, origin: origin)
        #expect(tilt.x == 0.3)
        #expect(tilt.y == -0.4)
    }

    @Test func leanIsClampedToTheMaximum() {
        let tilt = CardTilt.from(
            reading: RemoteTouchReading(x: 1, y: 1, touch: 1),
            origin: RemoteTouchReading(x: -1, y: -1, touch: 1)
        )
        #expect(tilt.yawDegrees == CardTilt.maxAngle)
        #expect(tilt.pitchDegrees == CardTilt.maxAngle)
        #expect(tilt.magnitude == 1)
        #expect(tilt.sheenOpacity == CardTilt.maxSheen)
    }

    @Test func lightEntersOppositeTheThumb() {
        let tilt = CardTilt(x: 1, y: 0)
        #expect(tilt.sheenStart.x == 0)
        #expect(tilt.sheenEnd.x == 1)
    }
}

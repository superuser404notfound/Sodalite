import CoreGraphics
import Testing
@testable import Sodalite

/// The touchpad pan's axis commit on the player. A diagonal used to commit to whichever axis was a
/// hair longer, so a down swipe toward the progress bar that drifted sideways scrubbed instead.
struct PlayerPanAxisTests {

    @Test func shortTravelStaysUndecided() {
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: 39, y: 0)) == .undetermined)
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: 0, y: -39)) == .undetermined)
    }

    @Test func aClearSwipeCommitsToItsAxis() {
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: -120, y: 20)) == .horizontal)
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: 15, y: 90)) == .vertical)
    }

    @Test func aDiagonalCommitsToNeither() {
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: -60, y: 50)) == .undetermined)
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: 45, y: 80)) == .undetermined)
    }

    @Test func exactlyTwiceAsLongIsEnough() {
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: 80, y: 40)) == .horizontal)
        #expect(PlayerPanAxis.resolve(translation: CGPoint(x: 20, y: -40)) == .vertical)
    }
}

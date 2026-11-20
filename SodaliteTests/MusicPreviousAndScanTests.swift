import Testing
import Foundation
@testable import Sodalite

/// LTM-205: Previous decides on the track being loaded, not on the outgoing track's clock.
struct MusicPreviousActionTests {

    @Test func previousWhileTheNextTrackLoadsStepsBackInsteadOfRestartingTheOldOne() {
        #expect(MusicPlaybackCoordinator.previousAction(currentTime: 90, loadInFlight: true, hasPrevious: true) == .stepBack)
    }

    @Test func previousOnTheFirstTrackWhileItLoadsDoesNothing() {
        #expect(MusicPlaybackCoordinator.previousAction(currentTime: 90, loadInFlight: true, hasPrevious: false) == .ignore)
    }

    @Test func settledPlaybackKeepsTheThreeSecondRule() {
        #expect(MusicPlaybackCoordinator.previousAction(currentTime: 3.5, loadInFlight: false, hasPrevious: true) == .restart)
        #expect(MusicPlaybackCoordinator.previousAction(currentTime: 2, loadInFlight: false, hasPrevious: true) == .stepBack)
        #expect(MusicPlaybackCoordinator.previousAction(currentTime: 2, loadInFlight: false, hasPrevious: false) == .restart)
    }
}

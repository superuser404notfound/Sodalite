import Testing
import Foundation
@testable import Sodalite

struct PlaybackEndEstimateTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("at normal speed the title ends after its remaining time")
    func normalSpeed() {
        #expect(PlaybackEndEstimate.endDate(now: now, remainingSeconds: 3600, rate: 1) == now + 3600)
    }

    @Test("a faster speed brings the end closer, a slower one pushes it out")
    func speedScalesTheRest() {
        #expect(PlaybackEndEstimate.endDate(now: now, remainingSeconds: 3600, rate: 1.5) == now + 2400)
        #expect(PlaybackEndEstimate.endDate(now: now, remainingSeconds: 3600, rate: 0.5) == now + 7200)
    }

    @Test("a paused title's end moves with the clock")
    func pausedEndFollowsTheClock() {
        let later = now + 600
        #expect(PlaybackEndEstimate.endDate(now: later, remainingSeconds: 3600, rate: 1) == later + 3600)
    }

    @Test("nothing left, no speed or an unusable rest has no end time",
          arguments: [(0.0, Float(1)), (-5, 1), (3600, 0), (.nan, 1), (.infinity, 1)])
    func noEstimate(remaining: Double, rate: Float) {
        #expect(PlaybackEndEstimate.endDate(now: now, remainingSeconds: remaining, rate: rate) == nil)
    }
}

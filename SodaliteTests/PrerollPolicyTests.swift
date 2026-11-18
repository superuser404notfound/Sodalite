import Testing
import Foundation
@testable import Sodalite

struct PrerollPolicyTests {
    /// Every flag at the value that lets a pre-roll play; each test flips exactly one.
    private func due(enabled: Bool = true, itemType: ItemType = .movie, isLive: Bool = false,
                     isLocal: Bool = false, isMultiviewTile: Bool = false, isQueuePlayback: Bool = false,
                     startFromBeginning: Bool = false, resumeTicks: Int64? = nil,
                     hasResumeOverride: Bool = false, alreadyConsumed: Bool = false) -> Bool {
        PrerollPolicy.shouldFetch(
            enabled: enabled, itemType: itemType, isLive: isLive, isLocal: isLocal,
            isMultiviewTile: isMultiviewTile, isQueuePlayback: isQueuePlayback,
            startFromBeginning: startFromBeginning, resumeTicks: resumeTicks,
            hasResumeOverride: hasResumeOverride, alreadyConsumed: alreadyConsumed)
    }

    @Test("a movie started from zero asks for its pre-rolls")
    func movieFromZero() {
        #expect(due())
        #expect(due(resumeTicks: 0))
    }

    @Test("Restart on a half-watched episode asks too")
    func restartedEpisode() {
        #expect(due(itemType: .episode, startFromBeginning: true, resumeTicks: 5_000_000_000))
    }

    @Test("a resume never plays a pre-roll")
    func resumeSkips() {
        #expect(!due(resumeTicks: 1))
        #expect(!due(hasResumeOverride: true))
    }

    @Test("everything that is not a first start of a movie or episode skips")
    func otherStartsSkip() {
        #expect(!due(enabled: false))
        #expect(!due(itemType: .video))
        #expect(!due(itemType: .tvChannel))
        #expect(!due(itemType: .unknown))
        #expect(!due(isLive: true))
        #expect(!due(isLocal: true))
        #expect(!due(isMultiviewTile: true))
        #expect(!due(isQueuePlayback: true))
        #expect(!due(alreadyConsumed: true))
    }

    @Test("the server's order stays, the main item and repeats go")
    func playableKeepsOrder() {
        let intros = ["b", "a", "m1", "a", ""].map { JellyfinItem(seriesStub: $0, name: $0) }
        #expect(PrerollPolicy.playable(intros, mainItemID: "m1").map(\.id) == ["b", "a"])
    }
}

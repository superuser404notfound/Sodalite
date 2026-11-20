import Foundation
import Testing
@testable import Sodalite

/// Sodalite#87: a prefetch is fetched at one rung. Played at another, the session would silently
/// ignore the viewer's choice (or re-encode what the viewer asked to keep original).
struct PrefetchedPlaybackInfoQualityTests {
    private let response = PlaybackInfoResponse(mediaSources: [], playSessionId: "ps")

    @Test func aPrefetchAtTheSameRungMatches() {
        let prefetch = PrefetchedPlaybackInfo(itemID: "a", quality: .mbps10, response: response)
        #expect(prefetch.matching("a", quality: .mbps10) != nil)
    }

    @Test func aPrefetchAtAnotherRungDoesNotMatch() {
        let prefetch = PrefetchedPlaybackInfo(itemID: "a", quality: .original, response: response)
        #expect(prefetch.matching("a", quality: .mbps4) == nil)
    }

    @Test func anotherItemNeverMatches() {
        let prefetch = PrefetchedPlaybackInfo(itemID: "a", quality: .original, response: response)
        #expect(prefetch.matching("b", quality: .original) == nil)
    }
}

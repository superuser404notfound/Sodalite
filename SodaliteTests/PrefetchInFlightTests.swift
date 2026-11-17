import Foundation
import Testing
@testable import Sodalite

/// BRW-203: overlapping `ImageCache.prefetch` runs must not load the same URL twice.
struct PrefetchInFlightTests {
    @Test func aSecondClaimOfTheSameUrlsGetsNothing() throws {
        let urls = try (0..<3).map { try #require(URL(string: "https://img.example/prefetch-claim-\($0).jpg")) }
        let first = PrefetchInFlight.claim(urls)
        let second = PrefetchInFlight.claim(urls)
        #expect(first == urls)
        #expect(second.isEmpty)
        PrefetchInFlight.release(first)
        #expect(PrefetchInFlight.claim(urls) == urls)
        PrefetchInFlight.release(urls)
    }

    @Test func repeatsWithinOneClaimCountOnce() throws {
        let url = try #require(URL(string: "https://img.example/prefetch-claim-dup.jpg"))
        let claimed = PrefetchInFlight.claim([url, url])
        #expect(claimed == [url])
        PrefetchInFlight.release(claimed)
    }
}

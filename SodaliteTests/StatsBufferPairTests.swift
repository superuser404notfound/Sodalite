import Testing
@testable import Sodalite

/// Sodalite#87: the remote-HLS bypass a capped transcode plays on has AVPlayer's buffer but no engine
/// cache, so the row read "+45.7 s · — cached" with a half that can never fill.
struct StatsBufferPairTests {
    @Test func withoutACacheOnlyTheBufferShows() {
        #expect(StatsOverlayView.formatBufferPair(seconds: 45.7, cachedBytes: nil) == "+45.7 s")
    }

    @Test func withACacheBothHalvesShow() {
        #expect(StatsOverlayView.formatBufferPair(seconds: 12.0, cachedBytes: 3 * 1_048_576)
                == "+12.0 s  ·  3 MB cached")
    }

    @Test func aCacheWithoutABufferKeepsItsPlaceholder() {
        #expect(StatsOverlayView.formatBufferPair(seconds: nil, cachedBytes: 2 * 1_048_576)
                == "—  ·  2 MB cached")
    }
}

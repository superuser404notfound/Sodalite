import Testing
import CoreGraphics
@testable import Sodalite

/// Sodalite#142: there was no way out of Now Playing on iOS.
///
/// The tier was picked from the horizontal size class alone, and a regular width class does not
/// promise a container the wide column fits in. An iPhone Plus / Max in landscape reports REGULAR
/// with about 420pt of usable height, while the cover, its spacing and the chrome need 638. The page
/// then grew past the screen, the ZStack centred the overflow, and the close button, an overlay on
/// that same stack, left the screen with it. Measured on an iPhone 17 Pro Max simulator: the top-left
/// corner was empty and the cover was cut off at the top.
///
/// So the decision is a measurement now, and this pins it. The iOS numbers are spelled out because
/// the test target builds for tvOS, where `NowPlayingMetrics` answers with the tvOS tier.
struct NowPlayingWideFitTests {

    /// The metrics the iOS regular tier hands the layout.
    private static let iOSMinimum = NowPlayingMetrics.wideMinimumSize(
        coverSide: 360,
        columnWidth: 400,
        spacing: 48,
        hPadding: 40,
        vPadding: 40
    )

    private static func fitsWide(_ container: CGSize, minimum: CGSize) -> Bool {
        container.width >= minimum.width && container.height >= minimum.height
    }

    @Test("The minimum is the sum of the metrics the layout itself uses")
    func minimumIsTheSumOfItsParts() {
        let minimum = Self.iOSMinimum
        #expect(minimum.width == 2 * 40 + 400 + 48 + NowPlayingMetrics.queueMinimumWidth)
        #expect(minimum.height == 2 * 40 + 360 + NowPlayingMetrics.columnSpacing + NowPlayingMetrics.chromeBlockHeight)
    }

    @Test("An iPhone Plus / Max in landscape is too short for the wide column")
    func phoneLandscapeFallsBackToTheStack() {
        // iPhone 17 Pro Max landscape, safe area off both ends: 956x440 becomes about 838x419.
        #expect(Self.fitsWide(CGSize(width: 838, height: 419), minimum: Self.iOSMinimum) == false)
    }

    @Test("An iPad keeps the wide column in both orientations")
    func padKeepsTheWideColumn() {
        // iPad Pro 11", safe area off both ends.
        #expect(Self.fitsWide(CGSize(width: 834, height: 1166), minimum: Self.iOSMinimum))
        #expect(Self.fitsWide(CGSize(width: 1210, height: 790), minimum: Self.iOSMinimum))
    }

    @Test("A narrow iPad window falls back rather than overflowing")
    func narrowPadWindowFallsBackToTheStack() {
        // Half of an 11" landscape is under the queue's own minimum width.
        #expect(Self.fitsWide(CGSize(width: 591, height: 790), minimum: Self.iOSMinimum) == false)
    }

    @Test("The tvOS band clears its own minimum")
    func tvBandFits() {
        #expect(Self.fitsWide(CGSize(width: 1920, height: 1080), minimum: NowPlayingMetrics.wideMinimumSize))
    }
}

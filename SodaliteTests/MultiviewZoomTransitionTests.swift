#if os(tvOS)
import CoreGraphics
import Testing
@testable import Sodalite

/// Sodalite#175: a tile's full screen zooms out of the tile and back into it.
@MainActor
struct MultiviewZoomTransitionTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Where a view filling `screen` lands under `transform`, applied about its centre as UIKit does.
    private func frame(under transform: CGAffineTransform) -> CGRect {
        screen.offsetBy(dx: -screen.midX, dy: -screen.midY)
            .applying(transform)
            .offsetBy(dx: screen.midX, dy: screen.midY)
    }

    private func expectClose(_ a: CGRect, _ b: CGRect) {
        #expect(abs(a.minX - b.minX) < 0.001)
        #expect(abs(a.minY - b.minY) < 0.001)
        #expect(abs(a.width - b.width) < 0.001)
        #expect(abs(a.height - b.height) < 0.001)
    }

    @Test func thePlayerStartsExactlyOnTheTile() {
        let tile = CGRect(x: 1000, y: 580, width: 880, height: 495)
        expectClose(frame(under: MultiviewZoomTransition.transform(onto: tile, from: screen)), tile)
    }

    /// The way back zooms the grid instead, so the tile has to fill the screen where the player stood.
    @Test func theGridStartsWithTheTileFillingTheScreen() {
        let tile = CGRect(x: 40, y: 40, width: 880, height: 495)
        let gridStart = MultiviewZoomTransition.transform(onto: tile, from: screen).inverted()
        let tileOnScreen = tile
            .offsetBy(dx: -screen.midX, dy: -screen.midY)
            .applying(gridStart)
            .offsetBy(dx: screen.midX, dy: screen.midY)
        expectClose(tileOnScreen, screen)
    }

    @Test func reduceMotionIsAPlainCut() {
        let tile = CGRect(x: 40, y: 40, width: 880, height: 495)
        #expect(MultiviewZoomTransition.zoomFrame(tileFrame: tile, reduceMotion: true) == nil)
        #expect(MultiviewZoomTransition.zoomFrame(tileFrame: tile, reduceMotion: false) == tile)
    }

    @Test func anUnknownOrDegenerateTileIsAPlainCut() {
        #expect(MultiviewZoomTransition.zoomFrame(tileFrame: nil, reduceMotion: false) == nil)
        #expect(MultiviewZoomTransition.zoomFrame(tileFrame: .zero, reduceMotion: false) == nil)
        #expect(MultiviewZoomTransition.zoomFrame(tileFrame: .null, reduceMotion: false) == nil)
        #expect(MultiviewZoomTransition.zoomFrame(tileFrame: .infinite, reduceMotion: false) == nil)
    }
}
#endif

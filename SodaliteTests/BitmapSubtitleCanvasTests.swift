import Testing
import Foundation
import CoreGraphics
@testable import Sodalite

/// Bitmap cue positions are normalized to the subtitle composition canvas, which is a plane of
/// its own: a 720p encode routinely carries the disc's 1920x1080 PGS plane. Scaling that plane by
/// coded video pixels assumes canvas and video share a pixel grid, true for a scope crop off a
/// disc (both 1920 wide) and false for a downscaled encode, where it blew the canvas up by 1.5x,
/// so the line rendered 1.5x too wide and ran off the bottom edge of the screen.
struct BitmapSubtitleCanvasTests {

    /// A typical authored dialogue line: centered, in the lower eighth of the plane.
    private let bottomLine = CGRect(x: 0.2, y: 0.86, width: 0.6, height: 0.06)
    private let tvBounds = CGSize(width: 1920, height: 1080)
    private let hdCanvas = CGSize(width: 1920, height: 1080)

    private func expectClose(_ a: CGFloat, _ b: CGFloat, _ label: String) {
        #expect(abs(a - b) < 0.5, "\(label): \(a) vs \(b)")
    }

    @Test("a 720p encode carrying the disc's 1080p plane keeps its line on screen, at authored size")
    func downscaledEncodeKeepsAuthoredGeometry() {
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: hdCanvas,
                                                       videoSize: CGSize(width: 1280, height: 720),
                                                       in: tvBounds)
        #expect(frame.maxY <= tvBounds.height)
        expectClose(frame.minX, 384, "minX")
        expectClose(frame.width, 1152, "width")
        expectClose(frame.minY, 928.8, "minY")
        expectClose(frame.height, 64.8, "height")
    }

    @Test("a 720p scope crop lands in the letterbox bar, not past the screen")
    func downscaledScopeCropStaysOnScreen() {
        // 2.39:1 cropped to 1280x536, PGS still authored on the 1920x1080 plane.
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: hdCanvas,
                                                       videoSize: CGSize(width: 1280, height: 536),
                                                       in: tvBounds)
        #expect(frame.maxY <= tvBounds.height)
        expectClose(frame.minY, 928.8, "minY")
        expectClose(frame.width, 1152, "width")
    }

    @Test("a full-resolution scope crop keeps its authored lower-bar placement")
    func scopeCropKeepsLowerBarPlacement() {
        // The case the canvas mapping was built for: video cropped to scope, canvas still 16:9,
        // and a line authored below the picture stays in the bar instead of riding up into it.
        let barLine = CGRect(x: 0.2, y: 0.90, width: 0.6, height: 0.05)
        let frame = SubtitleOverlayView.bitmapCueFrame(position: barLine,
                                                       canvas: hdCanvas,
                                                       videoSize: CGSize(width: 1920, height: 804),
                                                       in: tvBounds)
        expectClose(frame.minX, 384, "minX")
        expectClose(frame.width, 1152, "width")
        expectClose(frame.minY, 972, "minY")
        // Below the video picture (bottom edge at 138 + 804), still on screen.
        #expect(frame.minY > 942)
        #expect(frame.maxY <= tvBounds.height)
    }

    @Test("portrait phone pins the cue to the video band, not the screen bottom")
    func portraitPinsCueToVideoBand() {
        let bounds = CGSize(width: 390, height: 844)
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: hdCanvas,
                                                       videoSize: hdCanvas,
                                                       in: bounds)
        // Video band: 390x219.375 centered vertically.
        expectClose(frame.minX, 78, "minX")
        expectClose(frame.width, 234, "width")
        expectClose(frame.minY, 500.975, "minY")
        expectClose(frame.height, 13.1625, "height")
        #expect(frame.maxY <= 312.3125 + 219.375)
    }

    @Test("a cue whose canvas matches the coded video maps one to one onto the video rect")
    func matchingCanvasMapsOntoVideoRect() {
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: hdCanvas,
                                                       videoSize: hdCanvas,
                                                       in: tvBounds)
        expectClose(frame.minX, 384, "minX")
        expectClose(frame.minY, 928.8, "minY")
        expectClose(frame.width, 1152, "width")
    }

    @Test("anamorphic SD: a coded 720x576 canvas covers the 16:9 picture instead of overhanging it")
    func anamorphicCanvasWidensWithThePicture() {
        // DVB / DVD on 720x576 at 16:9 (pixel aspect 64:45): the engine reports the coded frame as
        // the canvas, the picture presents at 1024x576 and fills the 16:9 screen.
        let pixelAspect: CGFloat = 64.0 / 45.0
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: CGSize(width: 720, height: 576),
                                                       videoSize: CGSize(width: 720 * pixelAspect, height: 576),
                                                       pixelAspect: pixelAspect,
                                                       in: tvBounds)
        expectClose(frame.minX, 384, "minX")
        expectClose(frame.width, 1152, "width")
        expectClose(frame.minY, 928.8, "minY")
        expectClose(frame.height, 64.8, "height")
    }

    @Test("anamorphic cropped DVD: the canvas keeps its rows, only its width follows the pixels")
    func anamorphicCroppedRipKeepsRows() {
        // 720x432 cut out of a 720x480 DVD at pixel aspect 32:27; the engine keeps the 720x480
        // canvas since the widths match. The picture is 853.3x432 on screen units, canvas 853.3x480.
        let pixelAspect: CGFloat = 32.0 / 27.0
        let bounds = CGSize(width: 853.333, height: 432)
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: CGSize(width: 720, height: 480),
                                                       videoSize: CGSize(width: 720 * pixelAspect, height: 432),
                                                       pixelAspect: pixelAspect,
                                                       in: bounds)
        // Canvas row 0.86 * 480 = 412.8, minus the 24 rows cropped off the top.
        expectClose(frame.minY, 388.8, "minY")
        expectClose(frame.height, 28.8, "height")
        expectClose(frame.width, 512, "width")
    }

    @Test("unknown video dims fall back to the full-bounds layout")
    func unknownVideoDimsFallBackToBounds() {
        let frame = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                       canvas: hdCanvas,
                                                       videoSize: .zero,
                                                       in: tvBounds)
        expectClose(frame.minX, 384, "minX")
        expectClose(frame.minY, 928.8, "minY")
        expectClose(frame.width, 1152, "width")
        expectClose(frame.height, 64.8, "height")
    }

    @Test("the vertical-position dial shifts the cue by exactly its delta")
    func verticalShiftMovesCueByDelta() {
        let base = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                      canvas: hdCanvas,
                                                      videoSize: CGSize(width: 1280, height: 720),
                                                      in: tvBounds)
        let lifted = SubtitleOverlayView.bitmapCueFrame(position: bottomLine,
                                                        canvas: hdCanvas,
                                                        videoSize: CGSize(width: 1280, height: 720),
                                                        in: tvBounds,
                                                        verticalShift: -108)
        expectClose(lifted.minY, base.minY - 108, "lifted minY")
        expectClose(lifted.minX, base.minX, "minX unchanged")
    }
}

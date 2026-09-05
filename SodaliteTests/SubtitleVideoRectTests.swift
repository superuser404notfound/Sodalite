import Testing
import Foundation
import CoreGraphics
import AetherEngine
@testable import Sodalite

/// #120: cue geometry has to be measured against the rectangle the picture actually occupies,
/// and its result has to stay on screen. Two situations broke that, and both are here:
///
/// - Picture Size = Fill draws the video `.resizeAspectFill`, so on a non-16:9 raster the picture
///   covers the surface while the overlay still measured against the aspect-fit band.
/// - Even in Original, the subtitle plane is scaled to COVER the video rect (so a scope line
///   authored into the 16:9 letterbox bar stays in the bar). On a display narrower than the plane
///   that canvas overhangs the bounds and carries the cue off the bottom edge with it.
struct SubtitleVideoRectTests {

    private let hdCanvas = CGSize(width: 1920, height: 1080)
    private let tvBounds = CGSize(width: 1920, height: 1080)

    private func expectClose(_ a: CGFloat, _ b: CGFloat, _ label: String) {
        #expect(abs(a - b) < 0.5, "\(label): \(a) vs \(b)")
    }

    // MARK: - The rect the picture occupies

    @Test("aspect-fit leaves the picture inside the bounds, aspect-fill covers them")
    func videoRectFollowsGravity() {
        let raster = CGSize(width: 1440, height: 1080)
        let fit = SubtitleOverlayView.videoRect(videoSize: raster, in: tvBounds, fillsSurface: false)
        #expect(fit == CGRect(x: 240, y: 0, width: 1440, height: 1080))

        let fill = SubtitleOverlayView.videoRect(videoSize: raster, in: tvBounds, fillsSurface: true)
        #expect(fill == CGRect(x: 0, y: -180, width: 1920, height: 1440))
        // Covering means no gap on either axis, and the overflow is centered.
        #expect(fill.minX <= 0 && fill.maxX >= tvBounds.width)
        #expect(fill.minY <= 0 && fill.maxY >= tvBounds.height)
    }

    @Test("a 16:9 raster fills and fits identically, so Fill is a no-op there")
    func matchingAspectIsANoOp() {
        #expect(SubtitleOverlayView.videoRect(videoSize: hdCanvas, in: tvBounds, fillsSurface: true)
                == SubtitleOverlayView.videoRect(videoSize: hdCanvas, in: tvBounds, fillsSurface: false))
    }

    @Test("unknown video dims fall back to the full bounds under either gravity")
    func unknownDimsFallBack() {
        for fills in [true, false] {
            #expect(SubtitleOverlayView.videoRect(videoSize: .zero, in: tvBounds, fillsSurface: fills)
                    == CGRect(origin: .zero, size: tvBounds))
        }
    }

    // MARK: - Fill: the cue follows the picture

    /// The reported case: a 4:3 DVD raster on a 16:9 screen. In Fill the picture spans the full
    /// width with ~12.5% cropped top and bottom, while the fit band is a centered pillar at 75%
    /// of screen width. A cue measured against the pillar renders 25% too small and inset.
    @Test("a 4:3 raster in Fill sizes its cue against the picture, not the pillar")
    func fillWidensCueOnPillarboxedRaster() {
        let raster = CGSize(width: 1440, height: 1080)
        let line = CGRect(x: 0.2, y: 0.86, width: 0.6, height: 0.06)

        let fitFrame = SubtitleOverlayView.bitmapCueFrame(position: line, canvas: hdCanvas,
                                                          videoSize: raster, in: tvBounds,
                                                          fillsSurface: false)
        let fillFrame = SubtitleOverlayView.bitmapCueFrame(position: line, canvas: hdCanvas,
                                                           videoSize: raster, in: tvBounds,
                                                           fillsSurface: true)
        expectClose(fitFrame.width, 1152, "fit width")
        expectClose(fillFrame.width, 1536, "fill width")
        // Exactly the 25% the report predicted from reading the code.
        expectClose(fitFrame.width / fillFrame.width, 0.75, "fit/fill width ratio")
        expectClose(fillFrame.minX, 192, "fill minX")
    }

    /// Cropping the picture must not crop the subtitles out of existence: on this raster the whole
    /// lower eighth of the plane is off screen, which is where dialogue lines live.
    @Test("a cue that Fill would crop away is held at the bottom edge instead")
    func fillClampsCueBackOnScreen() {
        let frame = SubtitleOverlayView.bitmapCueFrame(
            position: CGRect(x: 0.2, y: 0.86, width: 0.6, height: 0.06),
            canvas: hdCanvas, videoSize: CGSize(width: 1440, height: 1080),
            in: tvBounds, fillsSurface: true)
        expectClose(frame.maxY, tvBounds.height, "maxY")
        expectClose(frame.minY, 993.6, "minY")
    }

    @Test("Fill on a scope raster crops sideways and still keeps the line on screen")
    func fillOnScopeRasterKeepsLineOnScreen() {
        let frame = SubtitleOverlayView.bitmapCueFrame(
            position: CGRect(x: 0.2, y: 0.86, width: 0.6, height: 0.06),
            canvas: hdCanvas, videoSize: CGSize(width: 1920, height: 804),
            in: tvBounds, fillsSurface: true)
        #expect(frame.maxY <= tvBounds.height)
        expectClose(frame.maxY, tvBounds.height, "maxY")
    }

    // MARK: - Original: a display narrower than the subtitle plane

    /// Measured on an iPhone 16 Pro against a 3840x1600 HEVC direct play with a PGS track, no
    /// setting involved: the picture band is 2318x966 at y 120, the 1920x1080 plane scales to
    /// 1303.9 pt inside 1206 pt of bounds, and a line authored at 0.89 of plane height ends at
    /// 1228.9, which is 22.9 pt past the bottom edge. The screenshot shows the second line of a
    /// two-line cue cut off exactly there.
    @Test("a scope title on a 2.17:1 display keeps its authored line fully on screen")
    func narrowDisplayHoldsAuthoredLineOnScreen() {
        let bounds = CGSize(width: 2318, height: 1206)
        let frame = SubtitleOverlayView.bitmapCueFrame(
            position: CGRect(x: 0.2, y: 0.89, width: 0.6, height: 0.09),
            canvas: hdCanvas, videoSize: CGSize(width: 3840, height: 1600), in: bounds)

        #expect(frame.maxY <= bounds.height)
        expectClose(frame.maxY, bounds.height, "maxY")
        expectClose(frame.height, 117.349, "height")   // size is untouched, only the offset moves
        expectClose(frame.minX, 463.6, "minX")
        expectClose(frame.minY, 1088.651, "minY")
    }

    // MARK: - The clamp itself

    @Test("a cue already inside the bounds is not moved")
    func clampLeavesFittingCueAlone() {
        #expect(SubtitleOverlayView.verticalClamp(
            CGRect(x: 0, y: 100, width: 10, height: 50), in: tvBounds) == 0)
    }

    @Test("a cue past an edge is pulled back by exactly the overhang")
    func clampPullsBackByOverhang() {
        #expect(SubtitleOverlayView.verticalClamp(
            CGRect(x: 0, y: 1050, width: 10, height: 50), in: tvBounds) == -20)
        #expect(SubtitleOverlayView.verticalClamp(
            CGRect(x: 0, y: -30, width: 10, height: 50), in: tvBounds) == 30)
    }

    /// A block taller than the bounds cannot satisfy both edges. Text is read from its first line,
    /// so the top edge wins and the overflow goes off the bottom.
    @Test("a cue taller than the bounds is anchored to the top edge")
    func clampPrefersTopWhenTooTall() {
        let dy = SubtitleOverlayView.verticalClamp(
            CGRect(x: 0, y: 200, width: 10, height: 1200), in: tvBounds)
        #expect(200 + dy == 0)
    }

    @Test("a clamp against zero-height bounds is a no-op rather than a division")
    func clampIgnoresEmptyBounds() {
        #expect(SubtitleOverlayView.verticalClamp(
            CGRect(x: 0, y: 900, width: 10, height: 50), in: .zero) == 0)
    }

    // MARK: - Placed text cues

    @Test("a placed cue is held below the top edge when Fill pushes the picture past it")
    func placedCueRespectsTopLimit() {
        let placement = SubtitleTextPlacement(alignment: 8, position: CGPoint(x: 0.5, y: 0.02))
        // Picture rect starts above the overlay, as .fill on a 4:3 raster does.
        let pushedUp = CGRect(x: 0, y: -180, width: 1920, height: 1440)
        let origin = SubtitleOverlayView.placedOrigin(
            placement: placement, blockSize: CGSize(width: 200, height: 100), in: pushedUp,
            margin: 80, verticalShift: 0, bottomLimit: .infinity, topLimit: 0)
        #expect(origin.y == 0)
    }

    @Test("the top limit wins over the bottom limit")
    func topLimitBeatsBottomLimit() {
        let origin = SubtitleOverlayView.placedOrigin(
            placement: SubtitleTextPlacement(alignment: 2, position: nil),
            blockSize: CGSize(width: 200, height: 100),
            in: CGRect(x: 0, y: 0, width: 1000, height: 500),
            margin: 80, verticalShift: 0, bottomLimit: 50, topLimit: 120)
        #expect(origin.y == 120)
    }

    @Test("without a top limit a placed cue is unchanged")
    func noTopLimitLeavesPlacementAlone() {
        let args = (placement: SubtitleTextPlacement(alignment: 2, position: nil),
                    block: CGSize(width: 200, height: 100),
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let withLimit = SubtitleOverlayView.placedOrigin(
            placement: args.placement, blockSize: args.block, in: args.frame,
            margin: 80, verticalShift: 0, bottomLimit: .infinity, topLimit: -.infinity)
        let withoutLimit = SubtitleOverlayView.placedOrigin(
            placement: args.placement, blockSize: args.block, in: args.frame,
            margin: 80, verticalShift: 0, bottomLimit: .infinity)
        #expect(withLimit == withoutLimit)
    }
}

import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// Sodalite#151: the seek readout on the stored-title transport.
///
/// Round 1 drew it beside the scrub clock above the track, and that clock is two clocks: 22 pt under
/// a trickplay frame, 56 pt in the middle of the screen when no frame has resolved. Which one a
/// viewer got was `ScrubPreviewProvider`'s answer for that position at that moment, so a burst could
/// change size and side of the track while the glyph was on screen. Round 2 moved it below the
/// track, to the knob, at the size the live rail draws it. What is pinned here is that there is one
/// size and one row, and that the card it left is no longer sized for a guest that never arrives.
@Suite("The stored-title seek readout (Sodalite#151)")
struct SeekReadoutChromeTests {

    private func size(_ view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    }

    /// Every readout the bar can draw: a lone press, a burst, and a hold at its ceiling.
    private let readouts: [SeekReadout] = [
        .press(seconds: 10, count: 1, direction: -1),
        .press(seconds: 90, count: 1, direction: 1),
        .press(seconds: 30, count: 12, direction: -1),
        .hold(rate: 15, direction: -1),
        .hold(rate: 480, direction: 1),
    ]

    // MARK: - One gesture, one size

    /// The point of the issue, as a number: the same press reports itself at the same size whatever
    /// is playing. The live rail asks `SeekReadoutMetrics` for both, so this is the stored-title bar
    /// holding the other end of it.
    @Test func bothTransportsDrawTheReadoutInTheSameRow() {
        #expect(LiveRailLabels.defaultRowHeight == SeekReadoutMetrics.standardRowHeight)
        #expect(LiveRailLabels.defaultFont == SeekReadoutMetrics.standardFont)
    }

    /// A readout taller than the row it crosses spends the difference upwards, where the track is,
    /// and the knob grows to 22 pt at exactly the moment the readout exists.
    @Test func theTimeRowHoldsEveryReadoutItCanDraw() {
        for readout in readouts {
            let drawn = size(SeekReadoutView(readout: readout)).height
            #expect(drawn <= SeekReadoutMetrics.standardRowHeight,
                    "\(readout) draws \(drawn) in a row of \(SeekReadoutMetrics.standardRowHeight)")
        }
    }

    /// The row also has to hold what it held before the readout ever crossed it, which on this bar is
    /// a `.callout` clock rather than the live rail's.
    @Test func theTimeRowHoldsItsOwnClocks() {
        let clock = size(Text(verbatim: "-01:23:45").font(.callout).fontWeight(.medium)).height
        #expect(clock <= SeekReadoutMetrics.standardRowHeight)
    }

    /// The count sits beside the glyph, never under it: a fourth press widens the readout, which is
    /// what lets the row be pre-sized at all. Width is also why the labels at the row's corners have
    /// to give way rather than the readout, and why that is measured instead of guessed.
    @Test func aBurstCountCostsWidthAndNotHeight() {
        let single = size(SeekReadoutView(readout: .press(seconds: 10, count: 1, direction: -1)))
        let burst = size(SeekReadoutView(readout: .press(seconds: 10, count: 9, direction: -1)))
        #expect(burst.height == single.height)
        #expect(burst.width > single.width)
    }

    /// Nothing the readout can say is wider than the space between the row's two clocks, so a
    /// readout the corner labels step aside for is always a readout that fits where they stood.
    @Test func noReadoutIsWiderThanTheGapBetweenTheCorners() {
        let elapsed = size(Text(verbatim: "01:23:45").font(.callout).fontWeight(.medium)).width
        let remaining = size(Text(verbatim: "-01:23:45").font(.callout).fontWeight(.medium)).width
        // The stored-title bar is 80 pt inside each edge of a 1920 pt screen.
        let row: CGFloat = 1920 - 160
        for readout in readouts {
            #expect(size(SeekReadoutView(readout: readout)).width < row - elapsed - remaining)
        }
    }

    // MARK: - A press that cannot move anything

    /// Round 3, from the device: standing at 0:00 the burst went on counting 5x, 6x, 7x while the
    /// knob was already against the stop, because the clamp that ate the jump ran after the count.
    /// A readout that counts presses the playhead never answered is worse than no readout, since the
    /// whole point of counting is to be able to tell a four-press burst from a three-press one.
    @Test func aPressAgainstTheStopLandsWhereItAlreadyIs() {
        let hour = 3600.0
        #expect(PlayerViewModel.jumpTarget(from: 0, seconds: -10, duration: hour, ceiling: 1) == 0)
        #expect(PlayerViewModel.jumpTarget(from: 1, seconds: 10, duration: hour, ceiling: 1) == 1)
    }

    /// The other half of the same rule: a press that has anywhere to go still goes there, including
    /// the short one that runs into the stop from five seconds out.
    @Test func aPressWithSomewhereToGoStillMoves() {
        let hour = 3600.0
        #expect(PlayerViewModel.jumpTarget(from: 0.5, seconds: -10, duration: hour, ceiling: 1) < 0.5)
        let fiveSecondsIn = Float(5.0 / hour)
        let landed = PlayerViewModel.jumpTarget(from: fiveSecondsIn, seconds: -10,
                                                duration: hour, ceiling: 1)
        #expect(landed == 0)
        #expect(landed != fiveSecondsIn)
    }

    /// On live the stop is not the end of the rail. The part of a programme block that has not aired
    /// is drawn and cannot be aimed at (Sodalite#104), so a forward press stops at the live edge, and
    /// a press that is already there is a press that cannot move.
    @Test func aLivePressStopsAtTheLiveEdge() {
        #expect(PlayerViewModel.jumpTarget(from: 0.7, seconds: 3000, duration: 600, ceiling: 0.8)
                == 0.8)
        #expect(PlayerViewModel.jumpTarget(from: 0.8, seconds: 30, duration: 600, ceiling: 0.8)
                == 0.8)
    }

    // MARK: - What the preview card is left holding

    /// The card's clock row was sized for a glyph that stood beside it, and that glyph moved below
    /// the track. A row that still reserves the glyph's height is a gap under the frame that nothing
    /// ever fills, so the reservation goes with it.
    @Test func theCardClockRowIsItsOwnClockAndNothingElse() {
        let clock = size(Text(verbatim: "01:23:45")
            .font(.system(size: TransportBar.cardClockSize, weight: .semibold))).height
        #expect(TransportBar.cardClockRowHeight >= clock)
        let withGlyph = SeekReadoutMetrics.rowHeight(
            symbol: UIImage.SymbolConfiguration(pointSize: TransportBar.cardClockSize,
                                                weight: .semibold),
            lineHeight: UIFont.systemFont(ofSize: TransportBar.cardClockSize,
                                          weight: .semibold).lineHeight)
        #expect(TransportBar.cardClockRowHeight < withGlyph,
                "the card still reserves \(withGlyph) pt for a readout that is drawn below the track")
    }

    // MARK: - The measurement both bars ask

    /// `SeekReadoutMetrics` is what replaced a literal per bar, and the literal went a point short on
    /// the next tvOS: at `.callout`, 26.5 draws `gobackward.10` 39.5 pt tall and 27.0 draws it 41.0.
    @Test func theMeasuredRowCoversEveryGlyphItCanDraw() {
        #if os(tvOS)
        for name in SeekReadout.drawableGlyphNames {
            let drawn = size(Image(systemName: name).font(.callout)).height
            #expect(drawn <= SeekReadoutMetrics.standardRowHeight,
                    "\(name) draws \(drawn) in a row of \(SeekReadoutMetrics.standardRowHeight)")
        }
        #endif
    }

    /// A line taller than every glyph still gets a row it fits in: the measurement takes the larger
    /// of the two.
    @Test func theMeasuredRowNeverFallsShortOfItsTextLine() {
        let line = UIFont.systemFont(ofSize: 56, weight: .medium).lineHeight
        let height = SeekReadoutMetrics.rowHeight(
            symbol: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium),
            lineHeight: line)
        #expect(height >= line)
    }
}

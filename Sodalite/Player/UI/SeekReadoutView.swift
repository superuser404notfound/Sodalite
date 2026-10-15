#if !os(macOS)
// Player chrome for the UIKit host: it is display-only by construction, because
// PlayerHostController owns every press and moves a cursor through it. macOS has its own
// transport, whose controls handle their own clicks (Platforms/macOS/MacPlayerScreen.swift).
import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// Sodalite#104: a press and a hold, in the two languages they actually speak.
///
/// A press names its interval, because the destination is known before it lands, and a burst adds
/// up what it has covered (Sodalite#186: a count printed as "4x" read as a speed). A hold names its
/// rate and nothing else: a scan stepping 15x to 480x has no countable step, so a fixed-interval
/// glyph over it would be a lie. Nothing draws here on the touch transport, where a skip commits on
/// the tap that asked for it and flashes its own HUD.
///
/// Both readouts stay on ONE line, beside the clock rather than over it: a column of glyph over
/// count is 66 pt against the clock's 37 on tvOS, and a stack centred on the clock's line spends the
/// difference upwards, into the gap that separates this row from a knob which is 22 pt wide exactly
/// while the readout is drawn. The burst count reads the same beside the glyph as under it.
///
/// Sodalite#151: this and `SeekTrail` are what BOTH tvOS transports draw. They lived beside the live
/// rail while the live rail was their only reader, which is how the same press came to report itself
/// in two languages depending on what was playing.
struct SeekReadoutView: View {
    let readout: SeekReadout
    var font: Font = SeekReadoutMetrics.standardFont

    var body: some View {
        switch readout {
        case .press(let seconds, let count, let direction):
            HStack(spacing: 4) {
                Image(systemName: SkipGlyph.name(seconds: seconds, direction: direction))
                    .font(font)
                if count > 1 {
                    Text(verbatim: SeekReadout.burstTotal(seconds: seconds, count: count, direction: direction))
                        .font(font)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .transition(.opacity)
        case .hold(let rate, let direction):
            HStack(spacing: 4) {
                Image(systemName: direction < 0 ? "chevron.left.2" : "chevron.right.2")
                    .font(font)
                Text(verbatim: "\(rate)x")
                    .font(font)
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .transition(.opacity)
        }
    }
}

/// Sodalite#104: what the gesture has covered, as one continuous sweep from where it started to the
/// knob, whose weight follows a hold's rate. Sodalite#186: a burst of presses used to draw a comb of
/// notches here, and a comb on a timeline reads as chapter marks.
///
/// Sodalite#151: one implementation for both transports. Everything it needs is the knob, the
/// position the gesture started from and the readout, which either bar has to hand, and a second copy
/// of rail arithmetic is the mistake #104 already made once and paid for on a device round.
///
/// Drawn above the played fill and below the knob, so on a stored title the sweep melts into the tint
/// behind the playhead exactly as the chapter ticks beside it do.
struct SeekTrail: View {
    let readout: SeekReadout?
    /// Where the gesture started, in points across the track.
    let originX: CGFloat
    /// Where the knob is now, in points across the track.
    let knobX: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        switch readout {
        case .press:
            sweep(opacity: 0.3)
        case .hold(let rate, _):
            sweep(opacity: 0.15 + 0.35 * min(1, Double(rate) / Double(SeekReadout.holdStages.last?.rate ?? rate)))
        case nil:
            EmptyView()
        }
    }

    private func sweep(opacity: Double) -> some View {
        Capsule()
            .fill(.white.opacity(opacity))
            .frame(width: abs(knobX - originX), height: trackHeight)
            .offset(x: min(originX, knobX))
    }
}

/// How tall a row has to be to hold a seek readout, asked of the system rather than remembered.
///
/// Sodalite#104 round 2 measured this once for the live rail and pinned a literal, and the literal
/// went a point short on the next tvOS: at `.callout`, tvOS 26.5 draws `gobackward.10` 39.5 pt tall
/// and tvOS 27.0 draws the same symbol at 41.0, while `.callout` itself does not move between them.
/// A readout taller than its row spends the difference upwards, where the track is.
///
/// UIKit's symbol image reports exactly the height SwiftUI lays the same symbol out at, checked
/// across all twenty skip glyphs and both hold chevrons, which is what lets this be asked without
/// rendering a view. `LiveRailChromeTests` holds that equality, because it is the assumption the
/// whole number rests on.
enum SeekReadoutMetrics {
    /// `.callout` on the ten-foot bars, `.caption` on the phone, matching what each transport already
    /// gives the row the readout crosses.
    ///
    /// Sodalite#151 round 2: ONE size, because one gesture. Round 1 drew it at 22 pt under a
    /// trickplay card and at 28 pt beside the centred clock, against the live rail's 39.5, and which
    /// of those two a viewer got was decided by whether a thumbnail had resolved yet.
    static var standardFont: Font {
        #if os(tvOS)
        .callout
        #else
        .caption
        #endif
    }

    /// How tall a row has to be to hold a readout at `standardFont`, measured once.
    ///
    /// This row was 30 pt on both platforms, a height measured for the phone's `.caption`. tvOS
    /// `.callout` is 31 pt with a 36.99 pt line, so on the television the clock sat 3.5 pt above its
    /// own row and the press readout, a two-line column of 66 pt, sat 18 pt above it: that is where
    /// the gap to the scrubber went, and the knob grows to 22 pt at exactly the moment the readout
    /// exists.
    static var standardRowHeight: CGFloat {
        #if os(tvOS)
        tallestDrawnHeight
        #else
        20
        #endif
    }

    #if os(tvOS)
    private static let tallestDrawnHeight = rowHeight(
        symbol: UIImage.SymbolConfiguration(textStyle: .callout),
        lineHeight: UIFont.preferredFont(forTextStyle: .callout).lineHeight)

    /// The tallest glyph `SeekReadoutView` can draw at `configuration`, never shorter than the text
    /// line it stands beside.
    static func rowHeight(symbol configuration: UIImage.SymbolConfiguration,
                          lineHeight: CGFloat) -> CGFloat {
        let glyphs = SeekReadout.drawableGlyphNames
            .compactMap { UIImage(systemName: $0, withConfiguration: configuration)?.size.height }
        return ceil(max(lineHeight, glyphs.max() ?? lineHeight))
    }
    #endif
}
#endif

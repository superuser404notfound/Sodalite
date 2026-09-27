import SwiftUI
import UIKit

/// Sodalite#104: what the live rail says in words, for whichever transport is on screen.
///
/// The two ends of the block, the wall clock of the frame on screen tracking the knob between them,
/// and the programme that follows. One implementation, because the first round of this issue shipped
/// with the tvOS view holding its own copy of the rail arithmetic and the copy drifted: the badge and
/// the knob ended up answering different questions about the same edge. The two transports differ in
/// type scale and in nothing else, so that is the only thing they pass in.
struct LiveRailLabels: View {
    let viewModel: PlayerViewModel
    var font: Font = defaultFont
    var rowHeight: CGFloat = defaultRowHeight

    /// The type scale and the row height both belong to the readout rather than to this rail
    /// (Sodalite#151 round 2): the stored-title bar draws the same readout in a row of its own, and
    /// two rows reading the same platform twice is how the sizes came apart in the first place.
    static var defaultFont: Font { SeekReadoutMetrics.standardFont }
    static var defaultRowHeight: CGFloat { SeekReadoutMetrics.standardRowHeight }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(PlayerViewModel.clockLabel(for: viewModel.liveRailBlock.start))
                    Spacer(minLength: 0)
                    Text(PlayerViewModel.clockLabel(for: viewModel.liveRailBlock.end))
                }
                .font(font)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))

                // Hidden rather than pushed aside near the ends: there it would say what the end label
                // beside it already says, and a clock sliding out from under its own knob reads worse
                // than one that steps aside. The margin is a share of the width, so the phone hides it
                // sooner than the television does, which is the right answer on a 350pt rail.
                if let playheadClock, !clockCollides(width: width) {
                    HStack(spacing: 8) {
                        if let readout = viewModel.seekReadout, readout.direction == -1 {
                            SeekReadoutView(readout: readout, font: font)
                        }
                        Text(playheadClock)
                            .font(font)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        if let readout = viewModel.seekReadout, readout.direction == 1 {
                            SeekReadoutView(readout: readout, font: font)
                        }
                    }
                    .fixedSize()
                    .position(x: knobX(width), y: rowHeight / 2)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func knobX(_ width: CGFloat) -> CGFloat {
        max(0, min(width, width * CGFloat(viewModel.liveDisplayedProgress)))
    }

    private func clockCollides(width: CGFloat) -> Bool {
        let margin = max(60, width * 0.22)
        let x = knobX(width)
        return x < margin || x > width - margin
    }

    /// The wall clock of the frame on screen, or of the position a scrub is pointing at.
    private var playheadClock: String? {
        let block = viewModel.liveRailBlock
        guard block.seconds > 0 else { return nil }
        return PlayerViewModel.clockLabel(for: block.wallClock(at: viewModel.liveDisplayedProgress))
    }

}

/// Sodalite#104: what follows the block, under the rail that marks its end, which is the thing it
/// counts toward.
struct LiveNextUpLine: View {
    let viewModel: PlayerViewModel
    var font: Font = LiveRailLabels.defaultFont

    var body: some View {
        if let next = viewModel.liveNextProgram, let starts = next.startDate {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(Self.text(name: next.name, startsIn: starts.timeIntervalSince(Date())))
                    .font(font)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    /// "In 1h 41m: The OT", or the name alone once it has started. The countdown rounds up like
    /// every duration, so its last minute reads "In 1m" and never "In 0m" (Sodalite#165).
    static func text(name: String, startsIn seconds: TimeInterval) -> String {
        guard seconds > 0 else {
            return String(format: String(localized: "livetv.nextUp.now",
                                         defaultValue: "Next: %@"), name)
        }
        return String(format: String(localized: "livetv.nextUp",
                                     defaultValue: "In %1$@: %2$@"), seconds.durationDisplay, name)
    }
}

/// Sodalite#104: whether the picture is live is a STATUS, so the badge says it in the palette's
/// status colour and not in the accent.
///
/// It cannot be focused and it cannot be pressed, and it was filled with the exact colour every
/// focusable control in its row wears; on the phone it sat beside the Return to Live BUTTON in the
/// same tint, one of the two pressable and one not. The chip keeps the tint precisely so that the two
/// stop looking alike.
///
/// The colour moves to the WORD rather than the fill, which is both where the palette puts `success`
/// everywhere else and the only legible way round: a white label on a system-green fill measures
/// 2.0:1, under any reading of large text, while the green word on the rest fill measures 8.2:1 on
/// black and 3.4:1 against the brightest picture the control scrim lets through. The pill itself
/// therefore never changes, which is the honest drawing too, since what changes is the word.
struct LiveBadge: View {
    let isAtLiveEdge: Bool
    var font: Font = LiveRailLabels.defaultFont
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8

    var body: some View {
        Text("livetv.liveBadge")
            .font(font.bold())
            .foregroundStyle(isAtLiveEdge ? AnyShapeStyle(Color.Theme.success)
                                          : AnyShapeStyle(Color.white.opacity(0.5)))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule().fill(Color.Theme.restFillStrong))
    }
}

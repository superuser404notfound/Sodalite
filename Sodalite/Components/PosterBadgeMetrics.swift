import SwiftUI

/// Pill geometry, sized off the tier's poster width rather than the card the pill sits on.
///
/// Sizing a pill off its own card would put a 32pt pill on a landscape card next to a 20pt one on
/// the poster beside it, so every mark on artwork reads the tier's poster width instead.
enum PosterBadgeMetrics {
    /// The size of every piece of TEXT drawn on artwork: the corner pills and the remaining-time
    /// label beside the resume capsule.
    ///
    /// This shipped at 0.09, which is 19.8pt on the TV, and the reporter who asked for the pills
    /// came back with "slightly too big, reduce by about a third" (Sodalite#79). 0.06 is that third:
    /// 13.2pt on Apple TV, about half the 25pt card title under the poster, against 40 percent of
    /// the card width for the widest pill before and 27 after. Rendered on the tvOS simulator at
    /// 0.09, 0.08, 0.07 and 0.06 over a bright, busy still, with the watched disc and the resume row
    /// in frame, because the corner is judged as an ensemble and not one pill at a time.
    ///
    /// The floor is the smaller tiers: the same third would put the phone at 7.2pt, which is below
    /// anything readable at arm's length, so iPad and iPhone stop at 10pt (the phone barely moves,
    /// from 10.8, while the iPad loses its third and finally sits under its own 12pt card title).
    static func fontSize(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        max(10, posterWidth * 0.06 * scale)
    }

    /// Diameter of the watched check opposite the pills (Sodalite#89). Every comparable client
    /// draws that disc at 12 to 16 percent of the poster, and 0.13 puts it at 28.6pt on the TV,
    /// 20.8 on iPad and 15.6 on iPhone. It replaces a fixed `.title3`, which measured near 17
    /// percent on both tiers, grew with Dynamic Type on iOS, and ignored the card-scale setting
    /// while the card around it shrank.
    static func checkDiameter(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.13 * scale
    }

    /// Inset from the artwork corner. The fixed 10pt it replaces was 4.5 percent of a TV poster and
    /// 8.3 percent of a phone one, so the badge crowded the corner on the smallest tier.
    static func checkInset(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.045 * scale
    }

    /// Height of the resume capsule. 0.028 puts it at 6.2pt on the TV, 4.5 on iPad and 3.4 on
    /// iPhone, against the fixed 10pt it replaces, which was 4.5 percent of a TV poster and 8.3
    /// percent of a phone one and read as a bottom frame rather than as progress (Sodalite#99).
    /// The floor keeps it a visible bar rather than a hairline at the smallest tier.
    static func trackHeight(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        max(3, posterWidth * 0.028 * scale)
    }

    /// Capsule to remaining-time label. Wider than a text space at every tier, so the meter and the
    /// number read as two marks rather than as one run.
    static func labelGap(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        posterWidth * 0.036 * scale
    }

    /// The remaining-time label beside the resume capsule: the same size as the pills, not a step
    /// below them.
    ///
    /// It used to be 0.075 against their 0.09, because a bare number as loud as a scrimmed pill
    /// dominates the poster. That step was measured against the pill it stood next to, so shrinking
    /// the pill and leaving the number at 16.5pt turned the annotation into the loudest mark on the
    /// card (rendered, Sodalite#79 round 2). What separates the two marks is the pill's scrim and
    /// hairline, which a number set at the same point size still reads as quieter than.
    static func remainingLabelSize(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        fontSize(posterWidth: posterWidth, scale: scale)
    }

    /// Below this share of the card the meter stops reading as a meter, so the label is dropped and
    /// the capsule keeps the full row. Only a long localized hour form on the smallest poster gets
    /// there: measured against all 26 locales, zh-Hans "3小时48分钟" is the single case.
    static let minimumTrackShare: CGFloat = 0.35
}

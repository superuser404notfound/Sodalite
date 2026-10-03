import SwiftUI

/// Pill geometry, sized off the tier's poster width rather than the card the pill sits on.
///
/// Sizing a pill off its own card would put a 32pt pill on a landscape card next to a 20pt one on
/// the poster beside it, so every mark on artwork reads the tier's poster width instead.
enum PosterBadgeMetrics {
    /// The text size of the corner pills. The remaining-time badge beside the resume capsule stands
    /// one step above it, see ``remainingLabelSize(posterWidth:scale:)``.
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

    /// Padding around the text of a mark on artwork, as a share of its font size. One pair for the
    /// corner pills and the remaining-time badge, so the two read as the same kind of mark.
    static let pillHorizontalPadding: CGFloat = 0.42
    static let pillVerticalPadding: CGFloat = 0.18

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

    /// The remaining-time badge beside the resume capsule, one step above the corner pills.
    ///
    /// The two were one size while the number was bare (Sodalite#79 round 2): a naked number as
    /// large as a scrimmed pill was the loudest mark on the card. The number sits on a badge of its
    /// own since Sodalite#176, and unlike a pill it is READ, on every card of Continue Watching and
    /// from the sofa, where 13.2pt was reported as too small. 0.07 is 15.4pt on the TV and 11.2 on
    /// the iPad, the last step that stays under the iPad's 12pt card title; the phone keeps the
    /// 10pt floor. Rendered on the tvOS simulator at 0.06, 0.07 and 0.08, and measured against all
    /// 26 locales: 0.08 is the size where the TV poster starts dropping a label.
    static func remainingLabelSize(posterWidth: CGFloat, scale: CGFloat) -> CGFloat {
        max(10, posterWidth * 0.07 * scale)
    }

    /// Below this share of the card the meter stops reading as a meter, so the badge is dropped and
    /// the capsule keeps the full row. Only a long localized hour form on the smallest poster gets
    /// there: measured against all 26 locales, zh-Hans "3小时48分钟" is the single case.
    ///
    /// It was 0.35 while the number was bare. The badge's padding costs 8.4pt on the phone poster,
    /// and at 0.35 that also dropped every Russian hour form ("3 ч 48 мин"), by under a point.
        static let minimumTrackShare: CGFloat = 0.33
}

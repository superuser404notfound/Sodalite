import SwiftUI

/// The viewer's own state drawn on top of artwork: the watched check, and the favourite heart
/// beside it on the episode strip.
///
/// `checkmark.circle.fill` cuts its check OUT of the disc, so under a single fill the check is not
/// drawn at all, it is the poster showing through a hole. On bright art that reads white by luck,
/// on busy or dark art the shape breaks up or disappears (Sodalite#89). Palette rendering paints
/// the glyph in the accent's own foreground and the disc in the tint, and a soft
/// shadow gives the disc an edge on bright stills. It was the only overlay on the artwork with no
/// contrast treatment at all: the pills opposite sit on a scrim with a hairline, and the resume bar
/// keeps an opaque track for the same reason. A white glyph was only legible on the dark accents:
/// on Silver it was white on near-white (Sodalite#207), so it takes `palette.foreground` like every
/// other glyph drawn on the accent.
///
/// Sized off the tier's poster width like those pills, not off the card it sits on, so a landscape
/// card wears the same badge as the poster beside it, it tracks the card-scale setting, and it stops
/// growing with the viewer's Dynamic Type setting on iOS.
struct ArtworkStateBadges: View {
    var isFavorite: Bool = false
    var isPlayed: Bool
    /// The tier's poster width, not this card's width.
    let posterWidth: CGFloat
    var scale: CGFloat = 1

    @Environment(\.appearanceTheme) private var appearanceTheme

    private var diameter: CGFloat { PosterBadgeMetrics.checkDiameter(posterWidth: posterWidth, scale: scale) }
    private var inset: CGFloat { PosterBadgeMetrics.checkInset(posterWidth: posterWidth, scale: scale) }

    var body: some View {
        if isFavorite || isPlayed {
            // One stack for both: pinned separately they would land on the same point.
            HStack(spacing: diameter * 0.22) {
                if isFavorite {
                    badge("heart.fill")
                }
                if isPlayed {
                    // Two styles, so the symbol renders as a palette: legible check, tinted disc.
                    badge("checkmark.circle.fill", glyph: appearanceTheme.palette.foreground.color)
                }
            }
            .padding(inset)
        }
    }

    @ViewBuilder
    private func badge(_ symbol: String, glyph: Color? = nil) -> some View {
        let image = Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: diameter, height: diameter)

        Group {
            if let glyph {
                image.foregroundStyle(glyph, .tint)
            } else {
                image.foregroundStyle(.tint)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: diameter * 0.12, y: diameter * 0.05)
    }
}

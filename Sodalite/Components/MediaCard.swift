import SwiftUI

enum MediaCardStyle: Sendable {
    case poster    // Vertical 2:3 (movies, series)
    case landscape // Horizontal 16:9 (episodes, continue watching)
    case square    // 1:1 (album / music covers)

}

struct MediaCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    /// Tried when `imageURL` is nil or fails (e.g. series Thumb to backdrop/episode still for Continue Watching).
    let fallbackURL: URL?
    let style: MediaCardStyle

    /// Passed explicitly because tvOS's `@Environment(\.isFocused)` doesn't propagate reliably through Button labels; caller forwards from `FocusableCard` or a `@FocusState` match.
    let isFocused: Bool

    /// Sodalite#66. Set where the row paints show-level art (Continue Watching on Backdrop or
    /// Thumb): a series backdrop is marketing art, so the spoiler veil stays off the image.
    let showsSeriesArtwork: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Enlarge factor from Appearance settings (1.0 normal), applied to every style so rows stay proportional.
    private var scale: CGFloat { dependencies.appearancePreferences.cardScale }

    private var cardSize: CGSize {
        let base = LayoutMetrics.current(hSizeClass).size(for: style)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }
    private var cardWidth: CGFloat { cardSize.width }

    /// Off the tier's poster width, not this card's, so a landscape card wears the same pill as the
    /// poster beside it (Sodalite#79). The watched badge opposite reads the same width (Sodalite#89).
    private var tierPosterWidth: CGFloat { LayoutMetrics.current(hSizeClass).posterSize.width }

    private var badgeFontSize: CGFloat {
        PosterBadgeMetrics.fontSize(posterWidth: tierPosterWidth, scale: scale)
    }
    private var cardHeight: CGFloat { cardSize.height }

    init(
        item: JellyfinItem,
        imageURL: URL?,
        fallbackURL: URL? = nil,
        style: MediaCardStyle = .poster,
        isFocused: Bool = false,
        showsSeriesArtwork: Bool = false
    ) {
        self.item = item
        self.imageURL = imageURL
        self.fallbackURL = fallbackURL
        self.style = style
        self.isFocused = isFocused
        self.showsSeriesArtwork = showsSeriesArtwork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            posterImage
            itemInfo
        }
        .frame(width: cardWidth)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityProgress)
    }

    private var posterImage: some View {
        AsyncCachedImage(url: imageURL, fallbackURL: fallbackURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle()
                    .fill(Color.Theme.surface)
                Image(systemName: iconForType)
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        // Sodalite#50: before the clip so the blur cannot bleed past the tile edge. No type check
        // here, the policy already passes everything that is not an unseen episode or movie.
        .spoilerVeil(for: item, style: .image, veils: !showsSeriesArtwork)
        .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
        // The clip is visual only, so without this the artwork stays TAPPABLE where it is invisible.
        // A fill-scaled image overflows the card on one axis by design: a 16:9 still in a 2:3 card
        // draws 320pt wide inside a 120pt frame, so it reached 100pt past both edges and, being a
        // later sibling in the row, sat on top of the card to its left and answered its taps
        // (measured on device, discussion #98: a tap at x=89 fired the card whose frame is 148..268).
        // Only cards whose artwork aspect matches their style were ever safe, which is why it showed
        // up on one row and not the rest.
        .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
        .overlay(alignment: .bottom) {
            progressOverlay
        }
        .overlay(alignment: .topLeading) {
            // Music cards are excluded: an album has no picture to describe (Sodalite#79).
            if style != .square {
                PosterBadgeOverlay(item: item, fontSize: badgeFontSize)
            }
        }
        .overlay(alignment: .topTrailing) {
            ArtworkStateBadges(
                isPlayed: item.userData?.played == true,
                posterWidth: tierPosterWidth,
                scale: scale
            )
        }
        .overlay(
            MediaFocusRing(
                cornerRadius: ArtworkCorner.radius,
                isFocused: isFocused
            )
        )
    }

    private var itemInfo: some View {
        // Always render the subtitle slot (even empty) so cards keep equal height; otherwise subtitle-less items stagger title y-positions across the row.
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.caption)
                .lineLimit(1)

            Text(displaySubtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var displayTitle: String {
        guard style == .landscape, item.type == .episode else { return item.name }
        return EpisodeMetadataFormatter.label(season: nil, episode: item.indexNumber,
                                              title: item.name)
    }

    private var displaySubtitle: String? {
        if item.type == .episode, let seriesName = item.seriesName {
            // Season only: the episode number is already on the title line above.
            return EpisodeMetadataFormatter.label(seriesName: seriesName,
                                                  season: item.parentIndexNumber,
                                                  episode: nil, title: nil)
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let resumeFraction {
            ResumeProgressBar(fraction: resumeFraction,
                              remaining: item.resumeRemainingTicks?.ticksToDurationDisplay,
                              posterWidth: tierPosterWidth,
                              scale: scale)
        }
    }

    /// nil means this card shows no progress at all, which is both the bar and what VoiceOver
    /// reads: one source, so the spoken description cannot describe something that is not drawn.
    private var resumeFraction: Double? {
        ResumeIndicator.cardFraction(
            style: style,
            posterProgressEnabled: dependencies.appearancePreferences.showPosterProgress,
            playedPercentage: item.userData?.playedPercentage,
            isPlayed: item.userData?.played == true,
            playbackPositionTicks: item.userData?.playbackPositionTicks
        )
    }

    /// Progress was purely visual before this, VoiceOver got nothing from the bar at all. Composed
    /// from a percent style and the same compact remaining string the label shows, so it carries no
    /// sentence of its own into 26 languages.
    private var accessibilityProgress: String {
        guard let resumeFraction else { return "" }
        let percent = resumeFraction.formatted(.percent.precision(.fractionLength(0)))
        guard let remaining = item.resumeRemainingTicks?.ticksToDurationDisplay else { return percent }
        return "\(percent), \(remaining)"
    }

    private var iconForType: String {
        switch item.type {
        case .movie: "film"
        case .series: "tv"
        case .episode: "play.rectangle"
        case .season: "tv"
        case .musicAlbum, .audio: "music.note"
        default: "photo"
        }
    }
}

import SwiftUI

struct SeerrMediaCard: View {
    let media: SeerrMedia
    /// Passed by the caller (same pattern as `MediaCard`); drives the focus stroke.
    var isFocused: Bool = false

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Same enlargement as `MediaCard`: the two stand in the same rows on Search and read as one
    /// family, so a setting that moved only the Jellyfin half would be the misalignment it fixes.
    private var scale: CGFloat { dependencies.appearancePreferences.cardScale }
    private var cardWidth: CGFloat { LayoutMetrics.current(hSizeClass).posterSize.width * scale }
    private var cardHeight: CGFloat { LayoutMetrics.current(hSizeClass).posterSize.height * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            posterImage
            itemInfo
        }
        .frame(width: cardWidth)
    }

    private var posterImage: some View {
        AsyncCachedImage(
            url: SeerrImageURL.poster(path: media.posterPath, size: .covering(ImageWidth.card))
        ) { image in
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
        .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
        // Bounded for the same reason as MediaCard's poster: a fill-scaled image overflows its
        // frame, and the clip above is visual only, so the invisible part stays tappable and
        // covers the neighbour drawn before it (discussion #98).
        .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
        .overlay(alignment: .topTrailing) {
            if let status = media.mediaInfo?.displayStatus, status != .unknown {
                SeerrStatusBadge(status: status, compact: true)
                    .padding(8)
            }
        }
        .overlay(
            MediaFocusRing(
                cornerRadius: ArtworkCorner.radius,
                isFocused: isFocused
            )
        )
    }

    private var itemInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(media.displayTitle)
                .font(.caption)
                .lineLimit(1)

            if let year = media.displayYear {
                Text(year)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconForType: String {
        switch media.mediaType {
        case .movie: "film"
        case .tv: "tv"
        case .person, .unknown: "person"
        }
    }
}

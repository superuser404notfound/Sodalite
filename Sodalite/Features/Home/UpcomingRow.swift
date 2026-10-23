import SwiftUI

/// The Upcoming row (Sodalite#198). Its own row rather than `HorizontalMediaRow`: nothing on these
/// cards can be played, marked or rated yet, so the card menu and the poster badge enrichment that
/// row brings would only offer actions on an episode that does not exist.
struct UpcomingRow: View {
    let items: [JellyfinItem]
    let imageURLProvider: (JellyfinItem) -> URL?
    let onItemSelected: (JellyfinItem) -> Void
    var itemLabel: ((JellyfinItem) -> String?)? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    @Environment(\.locale) private var locale
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat {
        shellPaysLeading ? metrics.rowLeading(shellPaysLeading: true) : metrics.rowInset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HomeRowType.upcoming.localizedTitle)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.leading, leadingInset)
                .padding(.trailing, metrics.rowInset)

            RowScrollView(leading: leadingInset, trailing: metrics.rowInset,
                          vertical: metrics.rowVerticalPadding) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(items, id: \.originKey) { item in
                        FocusableCard {
                            onItemSelected(item)
                        } content: { isFocused in
                            UpcomingCard(
                                item: item,
                                imageURL: imageURLProvider(item),
                                badge: HomeUpcoming.badge(
                                    for: item.premiereDate, now: Date(), calendar: .current, locale: locale
                                ),
                                isFocused: isFocused,
                                serverLabel: itemLabel?(item)
                            )
                        }
                    }
                }
            }
            .focusSectionCompat()
        }
    }
}

/// Landscape card with the show's art, its name, the episode number and when it airs.
struct UpcomingCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    let badge: String?
    let isFocused: Bool
    let serverLabel: String?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var scale: CGFloat { dependencies.appearancePreferences.cardScale }
    private var cardSize: CGSize {
        let base = LayoutMetrics.current(hSizeClass).size(for: .landscape)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }
    private var badgeFontSize: CGFloat {
        PosterBadgeMetrics.fontSize(posterWidth: LayoutMetrics.current(hSizeClass).posterSize.width, scale: scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(item.seriesName ?? item.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: cardSize.width)
        .accessibilityElement(children: .combine)
        .accessibilityValue(badge ?? "")
    }

    /// Number only: the title of an episode nobody has seen is exactly what the spoiler settings
    /// exist to hold back.
    private var subtitle: String {
        if let serverLabel { return serverLabel }
        let token = EpisodeMetadataFormatter.seasonEpisode(season: item.parentIndexNumber, episode: item.indexNumber)
        return token.isEmpty ? " " : token
    }

    private var artwork: some View {
        AsyncCachedImage(url: imageURL, fallbackURL: nil) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle()
                    .fill(Color.Theme.surface)
                Image(systemName: "calendar")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
        .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                PosterBadgePills(pills: [badge], fontSize: badgeFontSize)
            }
        }
        .overlay(
            MediaFocusRing(cornerRadius: ArtworkCorner.radius, isFocused: isFocused)
        )
    }
}

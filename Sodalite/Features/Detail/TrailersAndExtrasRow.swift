import SwiftUI

/// The detail page's 16:9 row of trailers and extras (Sodalite#179, trailers since #195). Trailers
/// lead, local ones on every platform and YouTube ones where the page can embed them, then the
/// extras. The heading names what is actually in it.
///
/// Its own row rather than `HorizontalMediaRow` because a YouTube trailer is not a server item: it
/// has no id the server knows, no user data, and its still comes from YouTube.
struct TrailersAndExtrasRow: View {
    let localTrailers: [JellyfinItem]
    let youTubeTrailers: [YouTubeTrailer]
    let extras: [JellyfinItem]
    let imageURLProvider: (JellyfinItem) -> URL?
    let fallbackURLProvider: (JellyfinItem) -> URL?
    let onItemSelected: (JellyfinItem) -> Void
    let onYouTubeSelected: (YouTubeTrailer) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    @Environment(\.openURL) private var openURL
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat {
        shellPaysLeading ? metrics.rowLeading(shellPaysLeading: true) : metrics.rowInset
    }

    static func title(hasTrailers: Bool, hasExtras: Bool) -> LocalizedStringKey {
        switch (hasTrailers, hasExtras) {
        case (true, true): "detail.trailersAndExtras"
        case (true, false): "detail.trailers"
        default: "detail.extras"
        }
    }

    private var hasTrailers: Bool { !localTrailers.isEmpty || !youTubeTrailers.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title(hasTrailers: hasTrailers, hasExtras: !extras.isEmpty))
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.leading, leadingInset)
                .padding(.trailing, metrics.rowInset)

            RowScrollView(leading: leadingInset, trailing: metrics.rowInset,
                          vertical: metrics.rowVerticalPadding) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(localTrailers, id: \.originKey) { itemCard($0) }
                    ForEach(youTubeTrailers) { trailer in
                        FocusableCard(opensMenuOnHold: true) {
                            onYouTubeSelected(trailer)
                        } content: { isFocused in
                            YouTubeTrailerCard(trailer: trailer, isFocused: isFocused)
                        }
                        #if !os(tvOS)
                        .contextMenu {
                            Button("detail.trailer.openInYouTube", systemImage: "arrow.up.forward.app") {
                                openURL(trailer.watchURL)
                            }
                        }
                        #endif
                    }
                    ForEach(extras, id: \.originKey) { itemCard($0) }
                }
            }
            .focusSectionCompat()
        }
    }

    private func itemCard(_ item: JellyfinItem) -> some View {
        FocusableCard(opensMenuOnHold: true) {
            onItemSelected(item)
        } content: { isFocused in
            MediaCard(
                item: item,
                imageURL: imageURLProvider(item),
                fallbackURL: fallbackURLProvider(item),
                style: .landscape,
                isFocused: isFocused
            )
        }
        .mediaContextMenu(for: item) { onItemSelected($0) }
    }
}

/// A landscape `MediaCard` for a trailer that lives on YouTube: same size, corner, focus ring and
/// caption, with YouTube's own still and "YouTube" where a server item shows its year.
private struct YouTubeTrailerCard: View {
    let trailer: YouTubeTrailer
    let isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var cardSize: CGSize {
        let base = LayoutMetrics.current(hSizeClass).size(for: .landscape)
        let scale = dependencies.appearancePreferences.cardScale
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCachedImage(url: trailer.thumbnailURL, fallbackURL: trailer.fallbackThumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Rectangle()
                        .fill(Color.Theme.surface)
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            .overlay(
                MediaFocusRing(
                    cornerRadius: ArtworkCorner.radius,
                    isFocused: isFocused
                )
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(trailer.title ?? String(localized: "detail.trailer"))
                    .font(.caption)
                    .lineLimit(1)
                Text(verbatim: "YouTube")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: cardSize.width)
        .accessibilityElement(children: .combine)
    }
}

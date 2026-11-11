import SwiftUI

/// Horizontal scroller of network/studio tiles (TMDB logo on a dark card); tap pushes a CatalogFilteredGridView. Mirrors Jellyseerr web's CompanyCard slider.
struct CatalogProviderRow: View {
    let titleKey: LocalizedStringKey
    /// A heading the user typed, shown as is instead of `titleKey`.
    var verbatimTitle: String? = nil
    let providers: [CatalogProvider]
    /// Destination chosen by caller: Catalog wraps in a `CatalogFilter`, Home translates to a Jellyfin Studios filter.
    let onSelect: (CatalogProvider) -> Void
    /// Per-provider sample backdrop resolver (local Jellyfin for home, Jellyseerr discover for catalog); nil falls back to the dark logo-only tile.
    var backdropFor: (CatalogProvider) -> URL? = { _ in nil }

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat { metrics.rowLeading(shellPaysLeading: shellPaysLeading) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (verbatimTitle.map { Text(verbatim: $0) } ?? Text(titleKey))
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.leading, leadingInset)
                .padding(.trailing, metrics.rowInset)

            RowScrollView(leading: leadingInset, trailing: metrics.rowInset,
                          vertical: metrics.rowVerticalPadding) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(providers) { provider in
                        ProviderTile(
                            provider: provider,
                            backdropURL: backdropFor(provider)
                        ) {
                            onSelect(provider)
                        }
                    }
                }
            }
            .focusSectionCompat()
        }
    }
}

private struct ProviderTile: View {
    let provider: CatalogProvider
    let backdropURL: URL?
    let action: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // The shared 16:9 tile size, so provider, genre and library rows line up.
    private var tile: CGSize {
        LayoutMetrics.current(hSizeClass)
            .tileSize(cardScale: dependencies.appearancePreferences.cardScale)
    }
    private var width: CGFloat { tile.width }
    private var height: CGFloat { tile.height }

    var body: some View {
        // Deliberately not ArtworkTile: this tile carries a centered duotone logo, not a
        // bottom-left name, and the logo needs the darker mid-tile gradient below to stay
        // readable on bright backdrops. The name only stands in when a provider has no logo.
        // FocusableCard not Button: tvOS layers an unsuppressable white halo on focused buttons (as GenreTile/SeerrMediaCard).
        FocusableCard(action: action) { isFocused in
            ZStack {
                if let backdropURL {
                    AsyncCachedImage(url: backdropURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(white: 0.08)
                    }
                    .frame(width: width, height: height)
                    .clipped()

                    // Heavier than the genre tile gradient so the duotone logo stays readable on bright backdrops.
                    LinearGradient(
                        colors: [.black.opacity(0.55), .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color(white: 0.08)
                }

                if let url = SeerrImageURL.duotoneLogo(path: provider.logoPath) {
                    AsyncCachedImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(28)
                    } placeholder: {
                        nameLabel
                    }
                } else {
                    nameLabel
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            .overlay(
                MediaFocusRing(
                    cornerRadius: ArtworkCorner.radius,
                    isFocused: isFocused
                )
            )
        }
    }

    private var nameLabel: some View {
        Text(provider.name)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }
}

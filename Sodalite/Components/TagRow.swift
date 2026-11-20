import SwiftUI

struct TagRow: View {
    let title: LocalizedStringKey
    /// A heading the user typed, shown as is instead of `title`.
    var verbatimTitle: String? = nil
    let tags: [TagCardData]
    var onTagSelected: ((TagCardData) -> Void)?

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (verbatimTitle.map { Text(verbatim: $0) } ?? Text(title))
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, metrics.rowInset)

            RowScrollView(leading: metrics.rowInset, trailing: metrics.rowInset,
                          vertical: metrics.rowVerticalPadding) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(tags) { tag in
                        GenreCard(data: tag) {
                            onTagSelected?(tag)
                        }
                    }
                }
            }
            .focusSectionCompat()
        }
    }
}

struct TagCardData: Identifiable, Sendable {
    let id: String
    let name: String
    let backdropURL: URL?
}

struct GenreCard: View {
    let data: TagCardData
    let action: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ArtworkTile(
            title: data.name,
            artworkURL: data.backdropURL,
            size: LayoutMetrics.current(hSizeClass)
                .tileSize(cardScale: dependencies.appearancePreferences.cardScale),
            action: action
        ) {
            ArtworkTileSurface()
        }
    }
}

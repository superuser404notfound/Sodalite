import SwiftUI

struct HorizontalMediaRow: View {
    let title: LocalizedStringKey
    /// Rendered verbatim instead of `title` for per-library rows whose heading is a runtime string, not a localization key.
    var verbatimTitle: String? = nil
    let items: [JellyfinItem]
    let imageURLProvider: (JellyfinItem) -> URL?
    /// Per-item fallback image tried when the primary fails (e.g. series Thumb to backdrop/still).
    var fallbackURLProvider: ((JellyfinItem) -> URL?)? = nil
    var onItemSelected: ((JellyfinItem) -> Void)?
    var cardStyle: MediaCardStyle = .poster
    /// Sodalite#66. The row paints show-level art rather than each item's own still, so the cards
    /// skip the spoiler blur (Continue Watching set to Backdrop or Thumb).
    var showsSeriesArtwork: Bool = false
    /// Overrides the tier's row inset so the row can line up with a host screen that insets differently.
    var inset: CGFloat? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var rowInset: CGFloat { inset ?? metrics.rowInset }
    /// With the sidebar beside the content (Sodalite#140) the rail and its gap ARE the left margin.
    /// `inset` overrides the tier but not the shell: a host screen that insets differently still
    /// has to start where every other row on the same TV starts.
    private var leadingInset: CGFloat {
        shellPaysLeading ? metrics.rowLeading(shellPaysLeading: true) : rowInset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let verbatimTitle {
                    Text(verbatimTitle)
                } else {
                    Text(title)
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .padding(.leading, leadingInset)
            .padding(.trailing, rowInset)

            RowScrollView(leading: leadingInset, trailing: rowInset,
                          vertical: metrics.rowVerticalPadding) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    // Per server: two servers can carry the same id, and a repeated identity draws a blank card.
                    ForEach(items, id: \.originKey) { item in
                        FocusableCard {
                            onItemSelected?(item)
                        } content: { isFocused in
                            MediaCard(
                                item: item,
                                imageURL: imageURLProvider(item),
                                fallbackURL: fallbackURLProvider?(item),
                                style: cardStyle,
                                isFocused: isFocused,
                                showsSeriesArtwork: showsSeriesArtwork
                            )
                        }
                    }
                }
            }
            // A row is its own focus section so vertical navigation can reach it from any column (#80).
            .focusSectionCompat()
            .enrichesPosterBadges(items)
        }
    }
}

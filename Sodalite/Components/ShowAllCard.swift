import SwiftUI

/// The last card of a capped Home row, opening the row's full list. Sized and spaced like the
/// `MediaCard`s beside it, caption slot included, so the row keeps one baseline.
struct ShowAllCard: View {
    let style: MediaCardStyle
    let isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var cardSize: CGSize {
        let base = LayoutMetrics.current(hSizeClass).size(for: style)
        let scale = dependencies.appearancePreferences.cardScale
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: ArtworkCorner.radius)
                    .fill(isFocused ? Color.Theme.focusFill : Color.Theme.restFill)
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title2)
                    Text("home.showAll")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .foregroundStyle(isFocused ? .primary : .secondary)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .overlay(MediaFocusRing(cornerRadius: ArtworkCorner.radius, isFocused: isFocused))

            // Empty title and subtitle lines, the height a MediaCard's caption takes.
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: " ").font(.caption)
                Text(verbatim: " ").font(.caption2)
            }
            .accessibilityHidden(true)
        }
        .frame(width: cardSize.width)
        .accessibilityElement(children: .combine)
    }
}

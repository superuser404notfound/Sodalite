import SwiftUI

/// The not-yet-loaded cell of a sparse grid (Sodalite#86): the card's footprint, no content.
struct PlaceholderCard: View {
    let style: MediaCardStyle
    let isFocused: Bool

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var size: CGSize {
        let base = LayoutMetrics.current(hSizeClass).size(for: style)
        let scale = dependencies.appearancePreferences.cardScale
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: ArtworkCorner.radius)
                .fill(Color.Theme.surface)
                .frame(width: size.width, height: size.height)
                .overlay(MediaFocusRing(cornerRadius: ArtworkCorner.radius, isFocused: isFocused))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: " ").font(.caption)
                Text(verbatim: " ").font(.caption2)
            }
        }
        .frame(width: size.width)
        .accessibilityHidden(true)
    }
}

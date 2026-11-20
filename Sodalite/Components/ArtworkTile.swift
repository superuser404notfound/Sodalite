import SwiftUI

/// The one 16:9 "artwork with a name on it" tile: Home's Genres and My Media rows, Catalog's genre
/// rows. Sodalite#84 was these drifting apart (one centered its label, its neighbour put it bottom
/// left), so scrim, label and shape live here once instead of three times.
///
/// `fallback` paints both the loading state and the no-artwork state, so a caller can hand over a
/// plain gradient, or a gradient carrying a generic icon and a label of its own.
///
/// A nil `title` draws no label over the artwork, and no scrim either: the scrim exists to keep a
/// label readable, so without one it would only dim the artwork. Callers whose artwork tends to
/// carry its own name (library images usually do) pass nil and put the label in `fallback`, where
/// it shows exactly when there is no artwork to name the tile. Such a caller must drop its own
/// copy while passing a title, else both are drawn on the same spot in the no-artwork case.
struct ArtworkTile<Fallback: View>: View {
    let title: String?
    let artworkURL: URL?
    let size: CGSize
    /// A server name pinned to the top corner (Sodalite#240). Outside `fallback` on purpose: the
    /// label in there is gone once the artwork loads, and library artwork usually carries the
    /// library's name, so two servers' "Movies" tiles looked identical.
    var serverBadge: String? = nil
    let action: () -> Void
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        // FocusableCard not Button: tvOS layers an unsuppressable white halo on focused buttons.
        FocusableCard(action: action) { isFocused in
            ZStack(alignment: .bottomLeading) {
                if let artworkURL {
                    AsyncCachedImage(url: artworkURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        fallback()
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                } else {
                    fallback()
                }

                if let title {
                    // A gradient, not a flat veil: the label sits at the bottom, so that is the
                    // only band that needs contrast, and dimming the whole frame greyed out the
                    // artwork these rows exist to show.
                    LinearGradient(
                        colors: [.black.opacity(0.15), .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    ArtworkTileLabel(title: title)
                }

                if let serverBadge {
                    ArtworkTileServerBadge(name: serverBadge)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            // Bounded for the same reason as MediaCard's poster: a fill-scaled image overflows its
            // frame, and the clip above is visual only, so the invisible part stays tappable and
            // covers the neighbour drawn before it (discussion #98).
            .contentShape(RoundedRectangle(cornerRadius: ArtworkCorner.radius))
            .overlay(
                MediaFocusRing(
                    cornerRadius: ArtworkCorner.radius,
                    isFocused: isFocused
                )
            )
        }
    }
}

/// The tile's name, wherever it is drawn. Its own view so a caller placing it inside `fallback`
/// gets the identical treatment instead of a second copy that can drift.
struct ArtworkTileLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .shadow(radius: 4)
            .lineLimit(2)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// The server a tile comes from, in the corner opposite the library icon.
struct ArtworkTileServerBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "server.rack")
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.Theme.scrimHeavy))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The neutral tile ground, shared by every caller that has no themed fallback of its own.
struct ArtworkTileSurface: View {
    var body: some View {
        LinearGradient(
            colors: [Color.Theme.surface, Color.Theme.surfaceElevated],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

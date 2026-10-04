import SwiftUI

/// "My Media" row: one tile per video library, opening it in the shared FilteredGridView.
struct LibraryRow: View {
    let titleKey: LocalizedStringKey
    let libraries: [JellyfinLibrary]
    /// A suffix for the tile name, the server's when two servers share a library name (Sodalite#85).
    var label: (JellyfinLibrary) -> String? = { _ in nil }
    let onSelect: (JellyfinLibrary) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.leading, metrics.rowLeading(shellPaysLeading: shellPaysLeading))
                .padding(.trailing, metrics.rowInset)

            RowScrollView(
                leading: metrics.rowLeading(shellPaysLeading: shellPaysLeading),
                trailing: metrics.rowInset,
                vertical: metrics.rowVerticalPadding
            ) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(libraries) { library in
                        LibraryTile(library: library, label: label(library)) {
                            onSelect(library)
                        }
                    }
                }
            }
            .focusSectionCompat()
        }
    }
}

private struct LibraryTile: View {
    let library: JellyfinLibrary
    let label: String?
    let action: () -> Void

    private var name: String { [library.name, label].compactMap { $0 }.joined(separator: " · ") }

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // The shared 16:9 tile size (see LayoutMetrics.landscapeSize).
    private var size: CGSize {
        LayoutMetrics.current(hSizeClass)
            .tileSize(cardScale: dependencies.appearancePreferences.cardScale)
    }

    /// Off by default, because a library image nearly always has the library's own name burnt into
    /// it and drawing ours on top reads as two captions on one tile. A viewer whose images carry no
    /// text turns it on and gets the name in the app's own font, like the Genres row below
    /// (Sodalite#84).
    private var drawsNameOverArtwork: Bool {
        dependencies.appearancePreferences.showLibraryNames
    }

    var body: some View {
        ArtworkTile(
            title: drawsNameOverArtwork ? name : nil,
            artworkURL: dependencies.jellyfinImageService.libraryArtworkURL(for: library),
            size: size,
            action: action
        ) {
            ZStack {
                ArtworkTileSurface()

                // The icon sits in the corner rather than above the name, which on a compact tile
                // would overlap it.
                Image(systemName: symbol(for: library.libraryType))
                    .font(.system(size: size.height * 0.22))
                    .foregroundStyle(.tint)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Only when the tile above is unlabelled, else ArtworkTile draws a second copy of
                // the name right on top of this one.
                if !drawsNameOverArtwork {
                    ArtworkTileLabel(title: name)
                }
            }
        }
        .accessibilityLabel(name)
    }

    private func symbol(for type: LibraryType) -> String {
        switch type {
        case .movies: "film"
        case .tvshows: "tv"
        case .homevideos: "video"
        case .boxsets: "square.stack"
        case .playlists: "list.bullet"
        default: "rectangle.stack"
        }
    }
}

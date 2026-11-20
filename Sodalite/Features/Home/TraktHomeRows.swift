import SwiftUI

/// One card of a Trakt row: the library's own item when the server has the title, else the Trakt
/// entry, which opens the Seerr page so it can be requested.
enum TraktHomeEntry: Identifiable {
    case owned(JellyfinItem)
    case catalog(TraktListItem, SeerrMedia)

    var id: String {
        switch self {
        case .owned(let item): "owned-\(item.originKey)"
        case .catalog(let entry, _): "catalog-\(entry.id)"
        }
    }
}

struct TraktHomeRowData: Identifiable {
    let type: HomeRowType
    let id: String
    /// nil for the watchlist, whose heading is the row type's localized title.
    let listName: String?
    let entries: [TraktHomeEntry]
}

enum TraktHomeRows {
    /// Titles the server does not have are kept only when they can be opened somewhere, which today
    /// means Seerr, and only when they carry a TMDB id Seerr can look up.
    static func build(snapshot: TraktListsSnapshot, index: TraktLibrary.Index,
                      includeCatalog: Bool) -> [TraktHomeRowData] {
        var rows: [TraktHomeRowData] = []
        let watchlist = entries(snapshot.watchlist, index: index, includeCatalog: includeCatalog)
        if !watchlist.isEmpty {
            rows.append(TraktHomeRowData(type: .traktWatchlist, id: "watchlist", listName: nil, entries: watchlist))
        }
        for list in snapshot.lists {
            let items = entries(list.items, index: index, includeCatalog: includeCatalog)
            guard !items.isEmpty else { continue }
            rows.append(TraktHomeRowData(type: .traktLists, id: "list-\(list.id)", listName: list.name, entries: items))
        }
        return rows
    }

    private static func entries(_ items: [TraktListItem], index: TraktLibrary.Index,
                                includeCatalog: Bool) -> [TraktHomeEntry] {
        var seen = Set<String>()
        var result: [TraktHomeEntry] = []
        for item in items {
            let owned = item.kind == .movie ? index.movie(item.ids) : index.show(item.ids)
            let entry: TraktHomeEntry
            if let owned {
                entry = .owned(owned)
            } else if includeCatalog, let tmdb = item.ids.tmdb {
                entry = .catalog(item, catalogMedia(item, tmdbID: tmdb))
            } else {
                continue
            }
            if seen.insert(entry.id).inserted { result.append(entry) }
        }
        return result
    }

    private static func catalogMedia(_ item: TraktListItem, tmdbID: Int) -> SeerrMedia {
        let year = item.year.map(String.init)
        return SeerrMedia(
            id: tmdbID,
            mediaType: item.kind == .movie ? .movie : .tv,
            title: item.kind == .movie ? item.title : nil,
            name: item.kind == .show ? item.title : nil,
            originalTitle: nil, originalName: nil, overview: nil,
            posterPath: nil, backdropPath: nil,
            releaseDate: item.kind == .movie ? year : nil,
            firstAirDate: item.kind == .show ? year : nil,
            voteAverage: nil, mediaInfo: nil
        )
    }
}

/// A Trakt row on Home: library cards and catalog cards side by side, in the list's own order.
struct TraktHomeRow: View {
    let row: TraktHomeRowData
    let imageURLProvider: (JellyfinItem) -> URL?
    let onItemSelected: (JellyfinItem) -> Void
    let onCatalogSelected: (SeerrMedia) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat { metrics.rowLeading(shellPaysLeading: shellPaysLeading) }

    private var ownedItems: [JellyfinItem] {
        row.entries.compactMap { if case .owned(let item) = $0 { item } else { nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let listName = row.listName {
                    Text(verbatim: listName)
                } else {
                    Text(row.type.localizedTitle)
                }
            }
            .font(.title3)
            .fontWeight(.semibold)
            .padding(.leading, leadingInset)
            .padding(.trailing, metrics.rowInset)

            RowScrollView(leading: leadingInset, trailing: metrics.rowInset,
                          vertical: metrics.rowVerticalPadding) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(row.entries) { entry in
                        switch entry {
                        case .owned(let item):
                            FocusableCard(opensMenuOnHold: true) {
                                onItemSelected(item)
                            } content: { isFocused in
                                MediaCard(item: item, imageURL: imageURLProvider(item), style: .poster,
                                          isFocused: isFocused)
                            }
                            .mediaContextMenu(for: item) { onItemSelected($0) }
                        case .catalog(let traktItem, let media):
                            FocusableCard {
                                onCatalogSelected(media)
                            } content: { isFocused in
                                SeerrMediaCard(media: media, isFocused: isFocused, posterURL: traktItem.posterURL)
                            }
                        }
                    }
                }
            }
            .focusSectionCompat()
            .enrichesPosterBadges(ownedItems)
        }
    }
}

import SwiftUI

/// How a collection page lays out its members, and which of them it shows.
enum CollectionMembers {
    enum Filter: String, CaseIterable, Identifiable {
        case all, movies, shows

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "library.filter.all"
            case .movies: "detail.collection.filter.movies"
            case .shows: "detail.collection.filter.shows"
            }
        }

        func admits(_ item: JellyfinItem) -> Bool {
            switch self {
            case .all: true
            case .movies: item.type == .movie
            case .shows: item.type == .series
            }
        }
    }

    /// Above this many members the list's overview rows cost more scrolling than they tell.
    static let listLimit = 12

    /// The list reads well for a franchise of a few films. A long collection, one holding further
    /// collections, or one whose covers are not posters is a shelf to browse, so it gets a grid.
    static func usesGrid(_ items: [JellyfinItem]) -> Bool {
        items.count > listLimit
            || items.contains { $0.type == .boxSet }
            || gridSections(items, filter: .all).contains { $0.style != .poster }
    }

    /// The Movies / Shows filter only where there is something to tell apart.
    static func offersFilter(_ items: [JellyfinItem]) -> Bool {
        items.contains { $0.type == .movie } && items.contains { $0.type == .series }
    }

    static func visible(_ items: [JellyfinItem], filter: Filter) -> [JellyfinItem] {
        offersFilter(items) ? items.filter(filter.admits) : items
    }

    /// One block of the grid, drawn in a single card shape.
    struct GridSection: Identifiable {
        let id: String
        let title: LocalizedStringKey?
        let items: [JellyfinItem]
        let style: MediaCardStyle
    }

    /// A server can give films and shows different covers (posters for one, landscape for the
    /// other). One shape for a mixed "All" would crop half of them, and it would flip whenever a
    /// later page shifted the majority, so each kind keeps its own shape and, where the shapes
    /// differ, its own block. Where they agree the grid stays one block in server order.
    static func gridSections(_ items: [JellyfinItem], filter: Filter) -> [GridSection] {
        let shown = visible(items, filter: filter)
        let single = [GridSection(id: "all", title: nil, items: shown,
                                  style: ArtworkShape.style(for: shown, default: .poster))]
        guard filter == .all, offersFilter(items) else { return single }

        let movies = items.filter { $0.type == .movie }
        let shows = items.filter { $0.type == .series }
        let rest = items.filter { $0.type != .movie && $0.type != .series }
        let groups: [GridSection] = [
            GridSection(id: "other", title: nil, items: rest,
                        style: ArtworkShape.style(for: rest, default: .poster)),
            GridSection(id: "movies", title: Filter.movies.title, items: movies,
                        style: ArtworkShape.style(for: movies, default: .poster)),
            GridSection(id: "shows", title: Filter.shows.title, items: shows,
                        style: ArtworkShape.style(for: shows, default: .poster)),
        ].filter { !$0.items.isEmpty }

        return Set(groups.map(\.style)).count > 1 ? groups : single
    }

    /// Pages until a short one: a server that cannot count ahead reports a guessed total, so the
    /// page size, not `TotalRecordCount`, says when the list is done.
    static let pageSize = 50
    static let memberCap = 600

    static func isLastPage(received: Int, loaded: Int) -> Bool {
        received < pageSize || loaded >= memberCap
    }
}

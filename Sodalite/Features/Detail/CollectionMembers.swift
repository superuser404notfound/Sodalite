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
            || ArtworkShape.style(for: items, default: .poster) != .poster
    }

    /// The Movies / Shows filter only where there is something to tell apart.
    static func offersFilter(_ items: [JellyfinItem]) -> Bool {
        items.contains { $0.type == .movie } && items.contains { $0.type == .series }
    }

    static func visible(_ items: [JellyfinItem], filter: Filter) -> [JellyfinItem] {
        offersFilter(items) ? items.filter(filter.admits) : items
    }

    /// Pages until a short one: a server that cannot count ahead reports a guessed total, so the
    /// page size, not `TotalRecordCount`, says when the list is done.
    static let pageSize = 50
    static let memberCap = 600

    static func isLastPage(received: Int, loaded: Int) -> Bool {
        received < pageSize || loaded >= memberCap
    }
}

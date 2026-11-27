import Foundation

/// What the Show All card at the end of a Home row opens (Sodalite#258): the row's whole list, in
/// the row's own order. A row gets the card only when its fetch left titles behind
/// (`HomeRowData.hasMore`).
///
/// Continue Watching, Next Up and Upcoming have none. They are short queues of what to watch next,
/// built by endpoints (`/UserItems/Resume`, `/Shows/NextUp`, an episode window merged with Seerr)
/// that a paged grid cannot ask for.
enum HomeShowAll {
    struct Grid {
        let query: ItemQuery
        let defaultSort: LibrarySort
        /// The row is a list rather than an order (favorites, collections, playlists), so the grid
        /// offers the sort picker. A Latest or Top Rated row's order is the point of the row, and a
        /// picked sort there would only turn it into the library grid.
        let offersSort: Bool
        var hidesAudioPlaylists = false
    }

    /// Grid pages, the size every Home grid pages in.
    static let pageSize = 50

    /// nil for a row with nothing behind it to page, and for All Movies, All Series and collection
    /// shelves, which open grids of their own (`HomeView.allItemsFilter`, `collectionShelfFilter`).
    static func grid(for row: HomeRowData, now: Date = Date()) -> Grid? {
        guard row.hasMore else { return nil }
        let fields = JellyfinEndpoint.homeRowFields
        func list(_ types: [ItemType], sort: LibrarySort, offersSort: Bool = false, isFavorite: Bool? = nil) -> Grid {
            Grid(
                query: ItemQuery(includeItemTypes: types, limit: pageSize, isFavorite: isFavorite, fields: fields),
                defaultSort: sort,
                offersSort: offersSort
            )
        }
        switch row.type {
        case .latestMovies:
            return list([.movie], sort: .newestAdded)
        case .latestShows:
            return Grid(
                query: ItemQuery(includeItemTypes: [.series], limit: pageSize, fields: fields + ",DateLastMediaAdded"),
                defaultSort: .newestEpisode,
                offersSort: false
            )
        case .recentlyAdded:
            return list([.movie, .series], sort: .newestAdded)
        case .recentlyReleasedMovies:
            return Grid(query: HomeReleaseRowQuery.movies(now: now, limit: pageSize), defaultSort: .newestReleased, offersSort: false)
        case .recentlyReleasedShows:
            // The episodes themselves: no series sort follows the newest aired episode, and the row
            // folds them only to keep one tile per show in sixteen.
            return Grid(query: HomeReleaseRowQuery.episodes(now: now, limit: pageSize), defaultSort: .newestReleased, offersSort: false)
        case .topRatedMovies:
            return list([.movie], sort: .highestRated)
        case .topRatedShows:
            return list([.series], sort: .highestRated)
        case .favorites:
            return list([.movie, .series, .boxSet], sort: .default, offersSort: true, isFavorite: true)
        case .favoriteEpisodes:
            return list([.episode], sort: LibrarySort(key: .episodeOrder, descending: false), isFavorite: true)
        case .collections:
            return list([.boxSet], sort: .default, offersSort: true)
        case .playlists:
            var grid = list([.playlist], sort: .default, offersSort: true)
            grid.hidesAudioPlaylists = true
            return grid
        case .libraryLatest:
            guard !row.isCollectionShelf, let libraryID = row.libraryID else { return nil }
            return libraryLatest(libraryID: libraryID, collectionType: row.collectionType)
        case .allMovies, .allSeries, .continueWatching, .nextUp, .upcoming,
             .myMedia, .genres, .discoverProviders, .traktWatchlist, .traktLists:
            return nil
        }
    }

    /// The grid's heading for a row without a custom title, the row's own. `HomeRowType.localizedTitle`
    /// is a `LocalizedStringKey`, which SwiftUI can draw but a `String` cannot be made from.
    static func title(for row: HomeRowData) -> String {
        switch row.type {
        case .latestMovies: String(localized: "home.latestMovies")
        case .latestShows: String(localized: "home.latestShows")
        case .recentlyAdded: String(localized: "home.recentlyAdded")
        case .recentlyReleasedMovies: String(localized: "home.recentlyReleasedMovies")
        case .recentlyReleasedShows: String(localized: "home.recentlyReleasedShows")
        case .topRatedMovies: String(localized: "home.topRatedMovies")
        case .topRatedShows: String(localized: "home.topRatedShows")
        case .favorites: String(localized: "home.favorites")
        case .favoriteEpisodes: String(localized: "home.favoriteEpisodes")
        case .collections: String(localized: "home.collections")
        case .playlists: String(localized: "home.playlists")
        case .libraryLatest:
            String(
                format: String(localized: "home.libraryLatest.format", defaultValue: "Latest in %@"),
                row.libraryName ?? ""
            )
        default: row.libraryName ?? ""
        }
    }

    /// A library's newest titles. Flat like the row, never grouped into collections: a freshly added
    /// movie would hide behind its box set.
    private static func libraryLatest(libraryID: String, collectionType: String?) -> Grid {
        let types: [ItemType]
        switch collectionType {
        case "movies": types = [.movie]
        case "tvshows": types = [.series]
        case "homevideos": types = [.video]
        default: types = [.movie, .series]
        }
        let isShows = collectionType == "tvshows"
        return Grid(
            query: ItemQuery(
                parentID: libraryID,
                includeItemTypes: types,
                limit: pageSize,
                fields: JellyfinEndpoint.homeRowFields + (isShows ? ",DateLastMediaAdded" : "")
            ),
            defaultSort: isShows ? .newestEpisode : .newestAdded,
            offersSort: false
        )
    }
}

extension LibrarySort {
    static let newestAdded = LibrarySort(key: .dateAdded, descending: true)
    static let newestEpisode = LibrarySort(key: .lastEpisodeAdded, descending: true)
    static let newestReleased = LibrarySort(key: .releaseDate, descending: true)
    static let highestRated = LibrarySort(key: .rating, descending: true)
}

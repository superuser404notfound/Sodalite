import SwiftUI

enum HomeRowType: String, Codable, Sendable, CaseIterable, Identifiable {
    // Declaration order = default display order for fresh installs / Reset (defaultConfig uses allCases.enumerated()); existing users keep their saved order.
    case continueWatching
    case nextUp
    case myMedia
    case favorites
    case favoriteEpisodes
    case latestMovies
    case latestShows
    /// Ordered by release/air date, unlike every Latest row above (those order by DateCreated).
    case recentlyReleasedMovies
    case recentlyReleasedShows
    case discoverProviders
    case collections
    case playlists
    case genres
    case recentlyAdded
    case topRatedMovies
    case topRatedShows
    case allMovies
    case allSeries
    /// Dynamic per-library "Latest in <library>" row; never from `allCases`, only instantiated by reconciliation (fills libraryID/libraryName/collectionType).
    case libraryLatest

    var id: String { rawValue }

    var defaultEnabled: Bool {
        switch self {
        // collections/playlists included: a server without either renders nothing (HomeViewModel
        // drops empty rows), so the default costs users who have none exactly one query each and
        // saves the rest a trip through Customize Home (mikepaggi, Sodalite#73).
        case .continueWatching, .nextUp, .myMedia, .favorites, .favoriteEpisodes, .latestMovies,
             .latestShows, .discoverProviders, .genres, .collections, .playlists:
            true
        default:
            false
        }
    }

    var cardStyle: MediaCardStyle {
        switch self {
        case .continueWatching, .nextUp, .favoriteEpisodes:
            .landscape
        default:
            .poster
        }
    }

    var usesBackdrop: Bool {
        switch self {
        case .continueWatching, .nextUp, .favoriteEpisodes:
            true
        default:
            false
        }
    }

    /// Genres show tag cards rather than media items.
    var isTagRow: Bool {
        switch self {
        case .genres:
            true
        default:
            false
        }
    }

    /// Row not sourced from Jellyfin (today only Discover/Jellyseerr): hardcoded provider list, pushes a Seerr-backed grid, not FilteredGridView.
    var isDiscoverProviderRow: Bool { self == .discoverProviders }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .continueWatching: "home.continueWatching"
        case .nextUp: "home.nextUp"
        case .latestMovies: "home.latestMovies"
        case .latestShows: "home.latestShows"
        case .recentlyReleasedMovies: "home.recentlyReleasedMovies"
        case .recentlyReleasedShows: "home.recentlyReleasedShows"
        case .allMovies: "home.allMovies"
        case .allSeries: "home.allSeries"
        case .favorites: "home.favorites"
        case .favoriteEpisodes: "home.favoriteEpisodes"
        case .topRatedMovies: "home.topRatedMovies"
        case .topRatedShows: "home.topRatedShows"
        case .recentlyAdded: "home.recentlyAdded"
        case .genres: "home.genres"
        case .collections: "home.collections"
        case .playlists: "home.playlists"
        case .discoverProviders: "home.discoverProviders"
        case .myMedia: "home.myMedia"
        case .libraryLatest: "home.latestMovies"
        }
    }

    var systemImage: String {
        switch self {
        case .continueWatching: "play.circle"
        case .nextUp: "forward"
        case .latestMovies: "film"
        case .latestShows: "tv"
        case .recentlyReleasedMovies: "calendar"
        case .recentlyReleasedShows: "calendar.badge.clock"
        case .allMovies: "film.stack"
        case .allSeries: "rectangle.stack"
        case .favorites: "heart.fill"
        case .favoriteEpisodes: "heart.rectangle"
        case .topRatedMovies: "star.fill"
        case .topRatedShows: "star.fill"
        case .recentlyAdded: "clock"
        case .genres: "tag"
        case .collections: "rectangle.stack.fill"
        case .playlists: "list.and.film"
        case .discoverProviders: "tv.badge.wifi"
        case .myMedia: "rectangle.grid.2x2"
        case .libraryLatest: "film"
        }
    }
}

struct HomeRowConfig: Codable, Sendable, Identifiable, Equatable {
    let type: HomeRowType
    var isEnabled: Bool
    var sortOrder: Int
    /// `.libraryLatest` only: scopes the Latest query and gives the row a stable identity across launches/server switches.
    var libraryID: String?
    var libraryName: String?
    /// `.libraryLatest` collectionType ("movies"/"tvshows"); drives which item type the Latest query asks for.
    var collectionType: String?

    /// Customize-list icon; `.libraryLatest` derives from collectionType so TV libraries don't get the "film" fallback (Sodalite#15).
    var systemImage: String {
        if type == .libraryLatest, collectionType == "tvshows" {
            return "tv"
        }
        return type.systemImage
    }

    /// `.libraryLatest` rows share an enum rawValue, so id folds in libraryID to stay unique/stable.
    var id: String {
        if type == .libraryLatest, let libraryID {
            return "libraryLatest:\(libraryID)"
        }
        return type.rawValue
    }

    static func defaultConfig() -> [HomeRowConfig] {
        // `.libraryLatest` is a template case; excluded here, added by reconciliation once libraries are known.
        HomeRowType.allCases
            .filter { $0 != .libraryLatest }
            .enumerated()
            .map { index, type in
                HomeRowConfig(type: type, isEnabled: type.defaultEnabled, sortOrder: index)
            }
    }
}

extension HomeRowConfig {
    /// Library types that get their own per-library "Latest" row.
    static let perLibraryLatestTypes: Set<String> = ["movies", "tvshows"]

    /// The aggregated row a per-library row splits its library out of.
    static func aggregatedLatestRow(forCollectionType collectionType: String?) -> HomeRowType? {
        switch collectionType {
        case "movies": .latestMovies
        case "tvshows": .latestShows
        default: nil
        }
    }

    /// Merge `stored` with server `libraries`: existing rows keep enabled/sortOrder, add a `.libraryLatest` per movies/tvshows lib (refresh name/type), drop vanished ones. Per-library rows are opt-in: they are appended disabled so a fresh install matches `resetToDefault` (aggregated latestMovies/latestShows on, per-library rows off) regardless of library count.
    ///
    /// A per-library row is only offered where its type has more than one library. With a single
    /// one it splits nothing off: it runs the same query as the aggregated row and renders the same
    /// tiles under the library's name (device report, 2026-08-23). A row that loses that reason
    /// (second library removed, or it predates this rule) is retired, and if the user had it on,
    /// the aggregated row is switched on in its place rather than leaving them one shelf short.
    ///
    /// `isFreshInstall` (nothing stored for the scope yet) lays the result out with
    /// `applyingSplitDefault`, the same rule Reset applies, so the two still land on one page.
    static func reconciled(
        stored: [HomeRowConfig],
        libraries: [JellyfinLibrary],
        isFreshInstall: Bool = false
    ) -> [HomeRowConfig] {
        let latestLibs = libraries.filter {
            perLibraryLatestTypes.contains($0.collectionType ?? "")
        }
        let liveIDs = Set(latestLibs.map(\.id))
        let splitTypes = Set(
            Dictionary(grouping: latestLibs) { $0.collectionType ?? "" }
                .filter { $0.value.count > 1 }
                .keys
        )
        let splitLibs = latestLibs.filter { splitTypes.contains($0.collectionType ?? "") }
        let splitIDs = Set(splitLibs.map(\.id))

        var retiredEnabledTypes: Set<String> = []
        var result = stored.filter { config in
            guard config.type == .libraryLatest else { return true }
            guard let libraryID = config.libraryID else { return false }
            if splitIDs.contains(libraryID) { return true }
            // Retired for redundancy, not because the library vanished: hand the state over. A row
            // whose library is gone takes its content with it, so it hands over nothing.
            if liveIDs.contains(libraryID), config.isEnabled, let type = config.collectionType {
                retiredEnabledTypes.insert(type)
            }
            return false
        }

        // Refresh name/collectionType on surviving dynamic rows.
        for i in result.indices where result[i].type == .libraryLatest {
            if let lib = splitLibs.first(where: { $0.id == result[i].libraryID }) {
                result[i].libraryName = lib.name
                result[i].collectionType = lib.collectionType
            }
        }

        // Append rows for libraries not yet represented, disabled by default (opt-in via Customize).
        var nextOrder = (result.map(\.sortOrder).max() ?? -1) + 1
        // Track appended ids: duplicate library ids would yield colliding composite ids and break SwiftUI Identifiable/ForEach.
        var knownIDs = Set(result.compactMap { $0.type == .libraryLatest ? $0.libraryID : nil })
        for lib in splitLibs where !knownIDs.contains(lib.id) {
            result.append(
                HomeRowConfig(
                    type: .libraryLatest,
                    isEnabled: false,
                    sortOrder: nextOrder,
                    libraryID: lib.id,
                    libraryName: lib.name,
                    collectionType: lib.collectionType
                )
            )
            knownIDs.insert(lib.id)
            nextOrder += 1
        }

        // A row type added in a later app version is missing from every persisted config, and this
        // is the only path that sees stored configs, so append it with its default state instead of
        // making the user hit Reset. Existing rows keep their saved isEnabled/sortOrder, which keeps
        // the pass idempotent.
        let presentTypes = Set(result.map(\.type))
        for type in HomeRowType.allCases
        where type != .libraryLatest && !presentTypes.contains(type) {
            result.append(HomeRowConfig(type: type, isEnabled: type.defaultEnabled, sortOrder: nextOrder))
            nextOrder += 1
        }

        // After the append above, so the aggregated row is guaranteed to be there to switch on.
        for collectionType in retiredEnabledTypes {
            guard let rowType = aggregatedLatestRow(forCollectionType: collectionType),
                  let index = result.firstIndex(where: { $0.type == rowType })
            else { continue }
            result[index].isEnabled = true
        }

        return isFreshInstall ? applyingSplitDefault(result) : result
    }

    /// The default for a type with several libraries: each library gets its own "Latest in X" row,
    /// standing where the aggregated row stood, and the aggregated row goes off. Mixing a second
    /// library into one shelf is what hid a TMDB Trending library inside Latest Movies (Discord,
    /// 2026-10-16). Only a fresh install and Reset apply it; a saved layout keeps its rows.
    static func applyingSplitDefault(_ configs: [HomeRowConfig]) -> [HomeRowConfig] {
        let perLibrary = configs.filter { $0.type == .libraryLatest }
        let splitTypes = Dictionary(grouping: perLibrary) { $0.collectionType ?? "" }
            .filter { $0.value.count > 1 }
            .keys
        guard !splitTypes.isEmpty else { return configs }

        var ordered = configs.sorted { $0.sortOrder < $1.sortOrder }
        for collectionType in splitTypes.sorted() {
            guard let aggregate = aggregatedLatestRow(forCollectionType: collectionType) else { continue }
            let isSplitRow = { (config: HomeRowConfig) in
                config.type == .libraryLatest && config.collectionType == collectionType
            }
            var split = ordered.filter(isSplitRow)
            ordered.removeAll(where: isSplitRow)
            guard let anchor = ordered.firstIndex(where: { $0.type == aggregate }) else { continue }
            ordered[anchor].isEnabled = false
            for index in split.indices { split[index].isEnabled = true }
            ordered.insert(contentsOf: split, at: anchor + 1)
        }
        for index in ordered.indices { ordered[index].sortOrder = index }
        return ordered
    }

    /// Reset static rows to default order/enabled state and keep the discovered `.libraryLatest` rows, laid out by `applyingSplitDefault` exactly as a fresh install lays them out.
    static func resetToDefault(current: [HomeRowConfig]) -> [HomeRowConfig] {
        var result = defaultConfig()
        var order = result.count
        for config in current where config.type == .libraryLatest {
            result.append(
                HomeRowConfig(
                    type: .libraryLatest,
                    isEnabled: false,
                    sortOrder: order,
                    libraryID: config.libraryID,
                    libraryName: config.libraryName,
                    collectionType: config.collectionType
                )
            )
            order += 1
        }
        return applyingSplitDefault(result)
    }
}

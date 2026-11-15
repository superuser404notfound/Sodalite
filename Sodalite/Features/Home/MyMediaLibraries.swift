import Foundation

/// Which Jellyfin views the My Media row offers, and how the tile's grid asks for their contents.
///
/// Collections and Playlists joined the video libraries here because My Media is the shortcut into
/// the server's own views, and those two are the ones a viewer asks for by name (Discord,
/// 2026-08-28). Both are views without a folder behind them, so they need a different query shape
/// than a real library, which is the part worth pinning down in tests.
enum MyMediaLibraries {
    /// Music and books stay out: neither opens into a grid this app can render.
    static let browsableCollectionTypes: Set<String> = [
        "movies", "tvshows", "homevideos", "mixed", "boxsets", "playlists",
    ]

    static func browsable(_ libraries: [JellyfinLibrary]) -> [JellyfinLibrary] {
        libraries.filter { browsableCollectionTypes.contains($0.collectionType ?? "") }
    }

    // MARK: All Movies / All Series tiles (Sodalite#240)

    /// Owner of the two "All" tiles. No Jellyfin server mints this id, so a tile never matches a
    /// real library in the layout, the label lookup or a grid query.
    nonisolated static let aggregateServerID = "sodalite.all"
    static let allMoviesID = "all-movies"
    static let allSeriesID = "all-series"

    nonisolated static func isAggregate(_ library: JellyfinLibrary) -> Bool {
        library.serverID == aggregateServerID
    }

    /// The item type an "All" tile opens, nil for a real library.
    static func aggregateType(_ library: JellyfinLibrary) -> ItemType? {
        guard isAggregate(library) else { return nil }
        switch library.id {
        case allMoviesID: return .movie
        case allSeriesID: return .series
        default: return nil
        }
    }

    /// "All Movies" once two libraries can hold movies, "All Series" once two can hold shows, on
    /// one server or across combined ones. With a single library the tile would open the same
    /// titles as that library's own tile. Hidden libraries count: hiding both "Movies" copies and
    /// keeping "Kids Movies" is exactly the setup the tile is for.
    static func aggregates(_ libraries: [JellyfinLibrary]) -> [JellyfinLibrary] {
        let types = libraries.compactMap(\.collectionType)
        var result: [JellyfinLibrary] = []
        if types.filter({ $0 == "movies" || $0 == "mixed" }).count >= 2 {
            result.append(aggregate(id: allMoviesID, name: String(localized: "home.allMovies"), collectionType: "movies"))
        }
        if types.filter({ $0 == "tvshows" || $0 == "mixed" }).count >= 2 {
            result.append(aggregate(id: allSeriesID, name: String(localized: "home.allSeries"), collectionType: "tvshows"))
        }
        return result
    }

    private static func aggregate(id: String, name: String, collectionType: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: name, collectionType: collectionType, imageTags: nil, serverID: aggregateServerID)
    }

    /// The tiles My Media lays out: the "All" tiles first, then the browsable libraries.
    static func tiles(_ libraries: [JellyfinLibrary]) -> [JellyfinLibrary] {
        let browsable = browsable(libraries)
        return aggregates(browsable) + browsable
    }

    /// A view Jellyfin lists under /Users/{id}/Views without a folder id that scopes its items. Their
    /// contents answer to the type filter alone, which is how both Home rows fetch them; scoping one
    /// by parentID is what returns an empty grid.
    static func isVirtualView(_ type: LibraryType) -> Bool {
        type == .boxsets || type == .playlists
    }

    /// A home-video library is a tree of folders the server types no further than `Folder` and
    /// `Video`, so it is walked like Jellyfin's own client does, one level per screen, rather than
    /// queried by type; a Movie/Series query over it came back empty (Sodalite#180).
    static func browsesFolders(_ type: LibraryType) -> Bool {
        type == .homevideos
    }

    /// One level of a folder-browsed library: the folder's direct children, folders and videos only
    /// (the photos the library may also hold have nothing to open into).
    static func folderQuery(parentID: String) -> ItemQuery {
        var query = ItemQuery(
            parentID: parentID,
            includeItemTypes: [.folder, .video],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 200,
            fields: JellyfinEndpoint.homeRowFields
        )
        query.recursive = false
        return query
    }

    /// A server that lists several collection libraries means each to hold its own folders, so
    /// those are scoped by their id like a real library. Jellyfin's single Collections view is
    /// the virtual one above.
    static func scopesCollections(_ library: JellyfinLibrary, among libraries: [JellyfinLibrary]) -> Bool {
        guard library.libraryType == .boxsets else { return false }
        return libraries.filter { $0.libraryType == .boxsets && $0.serverID == library.serverID }.count > 1
    }

    /// The grid a library opens into, from a My Media tile or its own tab. `scopesCollections`
    /// comes from `scopesCollections(_:among:)`, where the caller knows the server's library list.
    static func gridQuery(
        for library: JellyfinLibrary, grouping: CollectionGrouping, scopesCollections: Bool = false
    ) -> ItemQuery {
        // parentID scopes the grid, the types match the library.
        let types = itemTypes(for: library.libraryType)
        // Collapsing box sets inside the box-set view is meaningless, and a virtual view takes no parentID.
        let isVirtual = isVirtualView(library.libraryType) && !scopesCollections
        var query = ItemQuery(
            parentID: isVirtual ? nil : library.id,
            includeItemTypes: types,
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 200,
            // A grid cell renders name/year/index/series/watched plus the poster; People,
            // MediaStreams, MediaSources, Chapters and Trickplay were fetched, decoded and cached
            // for every tile and never read (Sodalite#68).
            fields: JellyfinEndpoint.homeRowFields
        )
        if browsesFolders(library.libraryType) {
            query = folderQuery(parentID: library.id)
        } else if !isVirtualView(library.libraryType) {
            // The only grids that defer to the server's "Group movies into collections" (Sodalite#44).
            // The server itself skips collapsing once the watch-status filter adds IsPlayed.
            query.collapseBoxSetItems = grouping.queryValue
        }
        return query
    }

    static func itemTypes(for type: LibraryType) -> [ItemType] {
        switch type {
        case .movies: [.movie]
        case .tvshows: [.series]
        case .boxsets: [.boxSet]
        case .playlists: [.playlist]
        default: [.movie, .series]
        }
    }

    /// Jellyfin answers IncludeItemTypes=Playlist with audio and video playlists alike, and a music
    /// playlist has no detail screen to open (Sodalite#73), so the playlists grid drops them.
    static func hidesAudioPlaylists(_ type: LibraryType) -> Bool {
        type == .playlists
    }
}

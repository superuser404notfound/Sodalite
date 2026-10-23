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

    /// The grid a library opens into, from a My Media tile or its own tab.
    static func gridQuery(for library: JellyfinLibrary, grouping: CollectionGrouping) -> ItemQuery {
        // parentID scopes the grid, the types match the library.
        let types = itemTypes(for: library.libraryType)
        // Collapsing box sets inside the box-set view is meaningless, and a virtual view takes no parentID.
        let isVirtual = isVirtualView(library.libraryType)
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
        } else if !isVirtual {
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

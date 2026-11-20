import Foundation

/// Collect, apply and copy one scope's home rows, the two Next Up switches, the collection grouping
/// and the library sorts as a unit. The profile record carries exactly this, and seeding a profile
/// copies exactly this. Combine servers is not part of it: which account a second server contributes
/// is decided per device, so the switch stays on the box that set it (audit SYNC-201).
enum ProfileHomeStore {
    static func collect(scope: String, stamp: Date) -> ProfileHomePayload {
        ProfileHomePayload(
            updatedAt: stamp,
            configsJSON: HomeRowConfig.rawConfigData(scope: scope),
            mergeCWNextUp: HomeRowConfig.mergeContinueWatchingNextUp(scope: scope),
            rewatchNextUp: HomeRowConfig.enableRewatchingNextUp(scope: scope),
            collectionGrouping: HomeRowConfig.collectionGrouping(scope: scope).rawValue,
            librarySorts: LibrarySortStore.allSorts(scope: scope),
            libraryLayoutJSON: LibraryLayout.rawData(scope: scope),
            heroMode: HomeHeroMode.rawStored(scope: scope),
            heroExcludedLibraries: HomeHeroLibraries.rawStored(scope: scope),
            droppedSeriesJSON: DroppedSeriesStore.rawData(scope: scope)
        )
    }

    /// Configs are only written when the payload has them: a scope that never customised its rows
    /// falls back to the defaults, and writing nil over that would not be the same thing.
    static func apply(_ payload: ProfileHomePayload, scope: String) {
        if let configs = payload.configsJSON {
            HomeRowConfig.setRawConfigData(configs, scope: scope)
        }
        HomeRowConfig.setMergeContinueWatchingNextUp(payload.mergeCWNextUp, scope: scope)
        HomeRowConfig.setEnableRewatchingNextUp(payload.rewatchNextUp, scope: scope)
        // An unknown mode is a newer build's, not "follow the server": the local one stays.
        if let grouping = CollectionGrouping(rawValue: payload.collectionGrouping) {
            HomeRowConfig.setCollectionGrouping(grouping, scope: scope)
        }
        LibrarySortStore.applySorts(payload.librarySorts, scope: scope)
        if let layout = payload.libraryLayoutJSON { LibraryLayout.setRawData(layout, scope: scope) }
        // An unknown mode is a newer build's: the local one stays.
        if let mode = payload.heroMode.flatMap(HomeHeroMode.init(rawValue:)) { HomeHeroMode.setStored(mode, scope: scope) }
        if let excluded = payload.heroExcludedLibraries { HomeHeroLibraries.setExcluded(Set(excluded), scope: scope) }
        if let dropped = payload.droppedSeriesJSON { DroppedSeriesStore.setRawData(dropped, scope: scope) }
    }

    /// Dropped shows stay behind: they are what one viewer gave up on, not a layout.
    static func copy(fromScope source: String, toScope target: String) {
        var payload = collect(scope: source, stamp: .distantPast)
        payload.droppedSeriesJSON = nil
        apply(payload, scope: target)
    }
}

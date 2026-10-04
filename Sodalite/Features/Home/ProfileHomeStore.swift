import Foundation

/// Collect, apply and copy one scope's home rows, the two Next Up switches, the collection grouping
/// and the library sorts as a unit. The profile record carries exactly this, and seeding a profile
/// copies exactly this.
enum ProfileHomeStore {
    static func collect(scope: String, stamp: Date) -> ProfileHomePayload {
        ProfileHomePayload(
            updatedAt: stamp,
            configsJSON: HomeRowConfig.rawConfigData(scope: scope),
            mergeCWNextUp: HomeRowConfig.mergeContinueWatchingNextUp(scope: scope),
            rewatchNextUp: HomeRowConfig.enableRewatchingNextUp(scope: scope),
            collectionGrouping: HomeRowConfig.collectionGrouping(scope: scope).rawValue,
            librarySorts: LibrarySortStore.allSorts(scope: scope),
            combineServers: CombinedServersPreferences(defaults: .standard).isEnabled(scope: scope),
            combineServersExcluded: CombinedServersPreferences(defaults: .standard).excludedServerIDs(scope: scope).sorted()
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
        let combined = CombinedServersPreferences(defaults: .standard)
        if let enabled = payload.combineServers { combined.setEnabled(enabled, scope: scope) }
        if let excluded = payload.combineServersExcluded { combined.setExcluded(Set(excluded), scope: scope) }
    }

    /// Combine servers stays behind: it names another profile's accounts on other servers, and a
    /// profile used for the first time must not start showing them (Sodalite#85).
    static func copy(fromScope source: String, toScope target: String) {
        var payload = collect(scope: source, stamp: .distantPast)
        payload.combineServers = nil
        payload.combineServersExcluded = nil
        apply(payload, scope: target)
    }
}

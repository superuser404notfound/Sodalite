import Foundation

/// The session a cached entry belongs to. Entries are items fetched under one server's token with one profile's library permissions and watched flags, so every read and write carries one: an unscoped key hands one session's results to the next, and a genre keyed by name ("Action") is literally the same file on two servers.
nonisolated struct CacheIdentity: Hashable, Sendable {
    let serverID: String
    let userID: String
}

/// A tile's cache key together with the session it belongs to. They travel as one value so a grid cannot be handed a key without the scope that makes it correct.
nonisolated struct FilterCacheScope: Hashable, Sendable {
    let key: String
    let identity: CacheIdentity
}

/// Persistent stale-while-revalidate cache for home + catalog filter-tile result sets (two slices: homeFilterItems, catalogPage), scoped per `CacheIdentity`. Backed by per-key JSON in `Library/Caches/FilterCache/`, NOT UserDefaults: tvOS caps CFPreferences at 1MB/domain and a populated provider tile (50+ JellyfinItem blobs) overflows it, SIGABRT inside `defaults.set` on first write. `nonisolated` + `@unchecked Sendable` (whole-file atomic IO, only the directory pointer is shared) so the trim can run off the main actor and precompute fan-outs can write without a hop; synchronous so views can hydrate `@State` from `init()` in one render pass.
nonisolated final class FilterCache: @unchecked Sendable {
    static let shared = FilterCache()

    private let directory: URL

    /// Filename layout marker: `<format>.<slice>.<serverID>.<userID>.<encoded key>.json`. Bumping it makes every older file unparseable, which is what `migrateAndTrim` deletes, so a format change needs neither a migration flag nor a version inside the JSON.
    private static let format = "v2"
    private static let homeItemsSlice = "homeItems"
    private static let catalogSlice = "catalog"

    /// How many identities keep entries. Removing the bulk wipes means the directory grows per identity instead of being emptied on every switch; one identity is bounded (~20 genre tiles, ~32 provider tiles, a few library grids and catalog pages), so a bound on identities is a bound on the directory. The number is a starting point, not a measurement. A size bound, not an expiry policy: entries stay valid until overwritten.
    static let identityLimit = 10

    // No timestamps (no expiry policy; refresh replaces wholesale); decode tolerates old files carrying a dropped `lastFetched`.
    private struct HomeItemsEntry: Codable {
        let items: [JellyfinItem]
    }

    struct CatalogEntry: Codable, Sendable {
        let items: [SeerrMedia]
        let totalPages: Int
    }

    convenience init() {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.init(directory: caches.appendingPathComponent("FilterCache", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    // MARK: - Filenames

    private func fileURL(slice: String, key: String, identity: CacheIdentity) -> URL {
        // Only the caller's key is encoded, and "." is deliberately out of the allowed set: it separates the segments, and a genre name carrying one ("Marvel Studios 2.0") would otherwise be indistinguishable from an identity boundary. A "/" ("Action/Adventure") would become a path separator and the write would fail inside try? into a permanent silent cache miss, so encoding is required either way.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        // Server and user ids are Jellyfin GUIDs: no separator, nothing to encode. A backend handing out ids that need encoding would break the parse below, not just the filename.
        let name = [Self.format, slice, identity.serverID, identity.userID, safeKey]
            .joined(separator: ".")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// The identity a file belongs to, or nil when it predates the current filename format. The key is the only segment that may hold anything, and it is encoded without ".", so exactly four separators precede it.
    private static func identity(ofFileNamed name: String) -> CacheIdentity? {
        let stem = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        let parts = stem.split(separator: ".", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == format,
              !parts[2].isEmpty, !parts[3].isEmpty
        else { return nil }
        return CacheIdentity(serverID: String(parts[2]), userID: String(parts[3]))
    }

    // MARK: - IO

    private func read<T: Decodable>(_ type: T.Type, slice: String, key: String, identity: CacheIdentity) -> T? {
        let url = fileURL(slice: slice, key: key, identity: identity)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, slice: String, key: String, identity: CacheIdentity) {
        let url = fileURL(slice: slice, key: key, identity: identity)
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic so a crash mid-flush keeps the prior file instead of a truncated blob that fails the next decode.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Home Smart Filter (resolved JellyfinItems)

    func homeFilterItems(filterKey: String, identity: CacheIdentity) -> [JellyfinItem]? {
        read(HomeItemsEntry.self, slice: Self.homeItemsSlice, key: filterKey, identity: identity)?.items
    }

    func setHomeFilterItems(_ items: [JellyfinItem], filterKey: String, identity: CacheIdentity) {
        write(HomeItemsEntry(items: items), slice: Self.homeItemsSlice, key: filterKey, identity: identity)
    }

    // MARK: - Catalog Filter Page 1

    func catalogPage(filterKey: String, identity: CacheIdentity) -> CatalogEntry? {
        read(CatalogEntry.self, slice: Self.catalogSlice, key: filterKey, identity: identity)
    }

    func setCatalogPage(_ items: [SeerrMedia], totalPages: Int, filterKey: String, identity: CacheIdentity) {
        write(
            CatalogEntry(items: items, totalPages: totalPages),
            slice: Self.catalogSlice, key: filterKey, identity: identity
        )
    }

    // MARK: - Invalidation

    /// Drops one profile's entries: the profile was removed, or its session ended.
    func evict(identity: CacheIdentity) {
        removeEntries { $0 == identity }
    }

    /// Drops every profile's entries for one server. Deleting an item is a server-wide fact, and removing a server takes its profiles with it.
    func evict(serverID: String) {
        removeEntries { $0.serverID == serverID }
    }

    /// Clears every entry regardless of identity; the factory reset.
    func clearAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeEntries(matching predicate: (CacheIdentity) -> Bool) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries {
            guard let identity = Self.identity(ofFileNamed: url.lastPathComponent),
                  predicate(identity)
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes files written before the current filename format, then keeps the `identityLimit` most recently written identities. `survivor` is the identity being switched TO: it is about to be read, and its files can be older than the ones the session is leaving behind, so it always ranks first. Synchronous file IO, so call it off the main actor.
    func migrateAndTrim(keeping survivor: CacheIdentity?) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var byIdentity: [CacheIdentity: (urls: [URL], newest: Date)] = [:]
        for url in entries {
            guard let identity = Self.identity(ofFileNamed: url.lastPathComponent) else {
                // Predates the current filename format, so no reader can reach it again.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            var bucket = byIdentity[identity] ?? (urls: [], newest: .distantPast)
            bucket.urls.append(url)
            bucket.newest = max(bucket.newest, modified)
            byIdentity[identity] = bucket
        }

        guard byIdentity.count > Self.identityLimit else { return }

        var ranked = byIdentity
            .sorted { lhs, rhs in
                if lhs.value.newest != rhs.value.newest { return lhs.value.newest > rhs.value.newest }
                // Identities written within one mtime granule must still rank deterministically, else a trim depends on dictionary order.
                return (lhs.key.serverID, lhs.key.userID) > (rhs.key.serverID, rhs.key.userID)
            }
            .map(\.key)
        if let survivor, let index = ranked.firstIndex(of: survivor) {
            ranked.remove(at: index)
            ranked.insert(survivor, at: 0)
        }
        for identity in ranked.dropFirst(Self.identityLimit) {
            for url in byIdentity[identity]?.urls ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

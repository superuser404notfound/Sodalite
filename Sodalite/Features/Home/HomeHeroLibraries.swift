import Foundation

/// Which libraries the Home banner draws from, per profile scope (Sodalite#238).
///
/// Stored as the libraries left OUT, keyed by `JellyfinLibrary.originKey`, so a library added on
/// the server later shows up in the banner without anyone opening Customize Home again.
nonisolated enum HomeHeroLibraries {
    /// The banner asks for movies and shows only, so these are the libraries that can feed it.
    static let eligibleCollectionTypes: Set<String> = ["movies", "tvshows", "mixed"]

    static func eligible(_ libraries: [JellyfinLibrary]) -> [JellyfinLibrary] {
        libraries.filter { eligibleCollectionTypes.contains($0.collectionType ?? "") }
    }

    private static func key(scope: String) -> String { "homeHeroExcludedLibraries.\(scope)" }

    static func excluded(scope: String) -> Set<String> {
        Set(rawStored(scope: scope) ?? [])
    }

    /// An emptied list is stored as empty, not removed: sync reads a missing list as "never
    /// chosen" and would leave the other devices on their old selection.
    static func setExcluded(_ keys: Set<String>, scope: String) {
        UserDefaults.standard.set(keys.sorted(), forKey: key(scope: scope))
    }

    /// The raw list for cloud sync: nil while this profile never touched the selection.
    static func rawStored(scope: String) -> [String]? {
        UserDefaults.standard.stringArray(forKey: key(scope: scope))
    }

    /// Whether a library key belongs to this server. Keys are `serverID|libraryID`.
    static func key(_ key: String, belongsTo serverID: String) -> Bool {
        key.hasPrefix("\(serverID)|")
    }

    /// The libraries of one server the banner may still use. Ineligible types stay out, so a
    /// Collections view never turns into an unscoped query.
    static func included(_ libraries: [JellyfinLibrary], serverID: String, excluded: Set<String>) -> [JellyfinLibrary] {
        // Spelled out rather than `originKey`, which is main-actor isolated; same format.
        eligible(libraries).filter { !excluded.contains("\($0.serverID ?? serverID)|\($0.id)") }
    }

    /// Part of the banner's cache and memory keys, so a changed selection never paints the titles
    /// of the old one. Empty while nothing is left out, which keeps the keys from before #238.
    static func signature(_ excluded: Set<String>) -> String {
        excluded.isEmpty ? "" : "|" + excluded.sorted().joined(separator: ",")
    }
}

import Foundation

/// Single source of truth for `FilterCache` keys: writers and readers share these factories so a key-format change can't make a reader miss a writer's blob (silent "loading flash on every tap"). Two namespaces (Home → JellyfinItem slice, Catalog → SeerrMedia slice). `nonisolated` throughout so precompute fan-out tasks avoid a MainActor hop. The session is NOT in here: `FilterCache` scopes every entry by `CacheIdentity` itself, so these stay pure (`CatalogFilter.cacheKey` doubles as its `Identifiable.id` and must not move when the session does).
enum FilterCacheKey {
    enum Home {
        /// Streaming-provider tile. Region is in the key: TMDB watch-providers are region-specific (Disney+ DE ≠ US lineup).
        nonisolated static func provider(id: Int, region: String) -> String {
            "home-\(id)-\(region)"
        }

        /// Genre filter keyed by name (Jellyfin queries genres by name, not id).
        nonisolated static func genre(name: String) -> String {
            "home-genre-\(name)"
        }

        /// My Media library grid. The grouping mode is in the key because it changes the shape of the result (collection tiles vs. single movies); a shared key would repaint the previous shape from cache after the setting flips.
        nonisolated static func library(id: String, grouping: CollectionGrouping) -> String {
            "library_\(id)_\(grouping.rawValue)"
        }
    }

    enum Catalog {
        nonisolated static func streamingService(watchProviderID: Int, region: String) -> String {
            "streamingService-\(watchProviderID)-\(region)"
        }

        nonisolated static func tvNetwork(id: Int) -> String {
            "tvNetwork-\(id)"
        }

        nonisolated static func movieStudio(id: Int) -> String {
            "movieStudio-\(id)"
        }

        nonisolated static func movieGenre(id: Int) -> String {
            "movieGenre-\(id)"
        }

        nonisolated static func tvGenre(id: Int) -> String {
            "tvGenre-\(id)"
        }
    }
}

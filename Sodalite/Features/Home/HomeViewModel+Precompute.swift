import SwiftUI

// MARK: - Background Precompute

extension HomeViewModel {

    /// Resolves every CatalogProviders.networks tile against the local library + TMDB watch-providers in the background so the home filter can drop empty tiles, and writes each result list to FilterCache for a synchronous tap. Throttled to one run per session (re-running each Home appearance is ~110 Seerr calls for no perceptible gain).
    func precomputeProviderCounts() async {
        if providerCountsComputedAt != nil { return }
        // Latch set at the END, not here: latching up front meant a cancelled/failed run (loadContent re-entry during the multi-second runtime is common) left the latch set and the replacement bailed, ending the session with partial counts.

        let region = Locale.current.region?.identifier ?? "US"
        let lib = libraryService
        let disc = discoverService
        let uid = userID

        // Build the TMDB map on MainActor first (tmdbID + CatalogProviders.networks are MainActor-isolated under default isolation). Slim fields on this 10 000-item all-library scan: only tmdbID + image tags are read, so homeRowFields + ProviderIds is all we need; defaultFields would pull People/MediaStreams/Chapters for the whole library, by far the biggest Home download (Sodalite#12).
        let allItemsQuery = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 10000,
            fields: JellyfinEndpoint.homeRowFields + ",ProviderIds"
        )
        // A failed/cancelled scan must NOT proceed with an empty tmdbMap: the resolve pass would then find only studio matches and overwrite good FilterCache with shrunken lists (TMDB-augment-only providers like Paramount+ would count 0 and hide for the session).
        guard let allItems = try? await libraryService.getItems(
            userID: userID, query: allItemsQuery
        ).items, !Task.isCancelled else { return }

        var tmdbMap: [Int: JellyfinItem] = [:]
        for item in allItems {
            if let id = item.tmdbID { tmdbMap[id] = item }
        }
        // Snapshot into a Sendable struct: CatalogProvider is MainActor-isolated, so it can't cross into the detached task directly.
        let providerInfos: [ProviderResolveInfo] = CatalogProviders.networks.map {
            ProviderResolveInfo(
                id: $0.id,
                studioNames: $0.jellyfinStudioNames,
                watchProviderID: $0.tmdbWatchProviderID
            )
        }
        let mapForTask = tmdbMap

        // Detached so the task-group closures don't inherit MainActor isolation.
        let resolved: [(Int, [JellyfinItem])] = await Task.detached(priority: .utility) {
            await withTaskGroup(
                of: (Int, [JellyfinItem]).self,
                returning: [(Int, [JellyfinItem])].self
            ) { group in
                var iter = providerInfos.makeIterator()
                let maxConcurrent = 4

                for _ in 0..<maxConcurrent {
                    guard let info = iter.next() else { break }
                    group.addTask {
                        let items = await Self.resolveProviderItems(
                            info: info, region: region,
                            tmdbMap: mapForTask,
                            libraryService: lib, discoverService: disc, userID: uid
                        )
                        return (info.id, items)
                    }
                }
                var collected: [(Int, [JellyfinItem])] = []
                while let result = await group.next() {
                    collected.append(result)
                    if let next = iter.next() {
                        group.addTask {
                            let items = await Self.resolveProviderItems(
                                info: next, region: region,
                                tmdbMap: mapForTask,
                                libraryService: lib, discoverService: disc, userID: uid
                            )
                            return (next.id, items)
                        }
                    }
                }
                return collected
            }
        }.value

        // The detached resolve doesn't inherit cancellation; a cancelled precompute must not write superseded results over the replacement run's.
        guard !Task.isCancelled else { return }

        // MainActor: write counts + cache + sample backdrop per provider.
        for (providerID, items) in resolved {
            providerItemCounts[providerID] = items.count
            FilterCache.shared.setHomeFilterItems(
                items,
                filterKey: FilterCacheKey.Home.provider(id: providerID, region: region),
                identity: cacheIdentity
            )
            // Backfill the backdrop only if the fast studio pass didn't set one; this resolver includes watch-provider matches, so it finds a sample for studio-tag-less tiles (Paramount+).
            if providerBackdrops[providerID] == nil,
               let sample = items.first,
               let url = imageService.backdropURL(for: sample, maxWidth: 640)
                   ?? imageService.posterURL(for: sample) {
                providerBackdrops[providerID] = url
            }
        }

        // Latch only after a fully-written pass (see note at top).
        providerCountsComputedAt = Date()
    }

    /// Pre-warms FilterCache for every on-screen genre tile so the first tap renders from disk. Mirrors the provider precompute (detached, capped, one run per session); grids still revalidate on open.
    func precomputeGenreCaches() async {
        if genreCachesComputedAt != nil { return }
        // Empty-bail lets the next Home appearance retry if the genres row genuinely had nothing yet.
        let genreNames: [String] = tagRows
            .filter { $0.type == .genres }
            .flatMap { $0.tags.map(\.name) }
        if genreNames.isEmpty { return }

        let lib = libraryService
        let uid = userID

        let resolved: [(String, [JellyfinItem])] = await Task.detached(priority: .utility) {
            await withTaskGroup(
                of: (String, [JellyfinItem]).self,
                returning: [(String, [JellyfinItem])].self
            ) { group in
                var iter = genreNames.makeIterator()
                let maxConcurrent = 4

                func enqueue(_ name: String) {
                    group.addTask {
                        let query = ItemQuery(
                            includeItemTypes: [.movie, .series],
                            sortBy: "SortName",
                            sortOrder: "Ascending",
                            limit: 50,
                            genres: [name],
                            fields: JellyfinEndpoint.homeRowFields
                        )
                        let items = (try? await lib.getItems(
                            userID: uid, query: query
                        ).items) ?? []
                        return (name, items)
                    }
                }

                for _ in 0..<maxConcurrent {
                    guard let next = iter.next() else { break }
                    enqueue(next)
                }
                var collected: [(String, [JellyfinItem])] = []
                while let result = await group.next() {
                    collected.append(result)
                    if let next = iter.next() { enqueue(next) }
                }
                return collected
            }
        }.value

        // A cancelled pass must not persist stale results or latch; leaving genreCachesComputedAt nil lets the next appearance run to completion.
        guard !Task.isCancelled else { return }

        // MainActor cache writes (the detached closure can't see FilterCache.shared's non-isolation under strict concurrency).
        for (name, items) in resolved where !items.isEmpty {
            FilterCache.shared.setHomeFilterItems(
                items, filterKey: FilterCacheKey.Home.genre(name: name), identity: cacheIdentity
            )
        }
        // Latch at the END: up front, a cancelled run marked the session "computed" with an empty cache.
        genreCachesComputedAt = Date()
    }

    /// Sendable snapshot of the CatalogProvider fields resolveProviderItems reads (CatalogProvider is MainActor-isolated; the resolve runs detached).
    struct ProviderResolveInfo: Sendable {
        let id: Int
        let studioNames: [String]
        let watchProviderID: Int?
    }

    /// Resolves one provider's items: studio-name match plus TMDB watch-provider augment (when it has a watch-provider id), merged + deduped. Static so the task group doesn't capture self.
    private static func resolveProviderItems(
        info: ProviderResolveInfo,
        region: String,
        tmdbMap: [Int: JellyfinItem],
        libraryService: JellyfinLibraryServiceProtocol,
        discoverService: SeerrDiscoverServiceProtocol?,
        userID: String
    ) async -> [JellyfinItem] {
        let studioQuery = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 200,
            studioNames: info.studioNames,
            fields: JellyfinEndpoint.homeRowFields
        )
        let studioItems = (try? await libraryService.getItems(
            userID: userID, query: studioQuery
        ).items) ?? []

        var phase2Items: [JellyfinItem] = []
        if let watchID = info.watchProviderID, let discover = discoverService {
            let providerTmdbIDs = await discover.collectWatchProviderTmdbIDs(
                providerID: watchID, region: region
            )
            phase2Items = providerTmdbIDs.compactMap { tmdbMap[$0] }
        }

        return ProviderMatchMerging.merge(phase1: studioItems, phase2: phase2Items)
    }

    func loadProviderBackdrops() async {
        // Only providers without a resolved backdrop (this pass has no per-session throttle, so without the filter it re-ran ~33 random-sample queries each loadContent just to overwrite already-resolved heroes).
        let providers = CatalogProviders.networks.filter { providerBackdrops[$0.id] == nil }
        guard !providers.isEmpty else { return }
        // Stage 1 collects a Sendable sample item per provider; URL construction (imageService isn't Sendable) happens on MainActor in stage 2.
        let pairs: [(Int, JellyfinItem)] = await withTaskGroup(
            of: (Int, JellyfinItem?).self,
            returning: [(Int, JellyfinItem)].self
        ) { group in
            // Bounded fan-out: at most maxConcurrent queries enqueued, not all ~33, so suspended tasks don't pile onto the HTTPClient limiter at once.
            var iter = providers.makeIterator()
            let maxConcurrent = 6

            func enqueue(_ provider: CatalogProvider) {
                group.addTask { [libraryService, userID] in
                    let query = ItemQuery(
                        includeItemTypes: [.movie, .series],
                        sortBy: "Random",
                        limit: 1,
                        studioNames: provider.jellyfinStudioNames,
                        fields: JellyfinEndpoint.homeRowFields
                    )
                    let item = try? await libraryService.getItems(userID: userID, query: query).items.first
                    return (provider.id, item)
                }
            }

            for _ in 0..<maxConcurrent {
                guard let next = iter.next() else { break }
                enqueue(next)
            }
            var collected: [(Int, JellyfinItem)] = []
            for await (id, item) in group {
                if let item { collected.append((id, item)) }
                if let next = iter.next() { enqueue(next) }
            }
            return collected
        }
        for (id, item) in pairs {
            if let url = imageService.backdropURL(for: item, maxWidth: 640) ?? imageService.posterURL(for: item) {
                providerBackdrops[id] = url
            }
        }
    }
}

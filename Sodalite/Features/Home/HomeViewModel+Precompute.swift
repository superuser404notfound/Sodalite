import SwiftUI

// MARK: - Background Precompute

extension HomeViewModel {

    // Every pass below is split in three: read its inputs off the view model, do the network work
    // with no reference to it, then write back only if it still exists and was not cancelled. A pass
    // that ran as a method on the view model held it for its whole multi-second runtime, and that
    // postponed the deinit that cancels it: after a profile switch the old pass kept going under the
    // next profile's token (403s on the previous user's id) and wrote shrunken provider lists into the
    // previous profile's FilterCache (Sodalite#169). The `owner` closure hands out the view model for
    // one statement at a time, so nothing holds it across an await.

    func precomputeProviderCounts() async {
        await Self.runProviderCounts { self }
    }

    /// Resolves every CatalogProviders.networks tile against the local library + TMDB watch-providers in the background so the home filter can drop empty tiles, and writes each result list to FilterCache for a synchronous tap. Throttled to one run per session (re-running each Home appearance is ~110 Seerr calls for no perceptible gain).
    static func runProviderCounts(_ owner: () -> HomeViewModel?) async {
        // Latch set at the END, not here: latching up front meant a cancelled/failed run (loadContent re-entry during the multi-second runtime is common) left the latch set and the replacement bailed, ending the session with partial counts.
        guard let inputs = owner()?.providerPassInputs(), inputs.pending else { return }

        let region = Locale.current.region?.identifier ?? "US"
        let lib = inputs.libraryService
        let disc = inputs.discoverService
        let uid = inputs.userID

        // Build the TMDB map on MainActor first (tmdbID + CatalogProviders.networks are MainActor-isolated under default isolation). Slim fields on this 10 000-item all-library scan: only tmdbID + image tags are read, so homeRowFields + ProviderIds is all we need; defaultFields would pull People/MediaStreams/Chapters for the whole library, by far the biggest Home download (Sodalite#12).
        let allItemsQuery = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 10000,
            fields: JellyfinEndpoint.homeRowFields + ",ProviderIds"
        )
        // A failed/cancelled scan must NOT proceed with an empty tmdbMap: the resolve pass would then find only studio matches and overwrite good FilterCache with shrunken lists (TMDB-augment-only providers like Paramount+ would count 0 and hide for the session).
        guard let allItems = try? await lib.getItems(
            userID: uid, query: allItemsQuery
        ).items, !Task.isCancelled else { return }

        var tmdbMap: [String: JellyfinItem] = [:]
        for item in allItems {
            if let id = item.tmdbID {
                tmdbMap[ProviderMatchMerging.tmdbKey(type: item.type, tmdbID: id)] = item
            }
        }
        // A combined Home joins every server's library into the map, the active server winning an id.
        // Only secondaries whose scan answered take part further down: a dead one would otherwise
        // cost one deadline per provider.
        var secondaries: [HomeSource] = []
        var secondaryMaps: [[String: JellyfinItem]] = []
        for source in inputs.secondaries {
            let run: @MainActor @Sendable () async -> [JellyfinItem]? = {
                try? await source.libraryService.getItems(userID: source.userID, query: allItemsQuery).items
            }
            guard let items = await Deadline.race(secondaryPassDeadline, { await run() }) ?? nil else { continue }
            var map: [String: JellyfinItem] = [:]
            for item in items {
                var stamped = item
                if stamped.serverID == nil { stamped.serverID = source.serverID }
                if let id = stamped.tmdbID { map[ProviderMatchMerging.tmdbKey(type: stamped.type, tmdbID: id)] = stamped }
            }
            secondaryMaps.append(map)
            secondaries.append(source)
        }
        if !secondaryMaps.isEmpty {
            tmdbMap = CombinedProviderMatch.unionTmdbMaps([tmdbMap] + secondaryMaps)
        }
        guard !Task.isCancelled else { return }
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
        let resolveTask = Task.detached(priority: .utility) {
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
        }
        // A detached task doesn't inherit cancellation on its own; without the handler, cancelling
        // providerCountsTask left this resolve running to completion (33 Jellyfin + ~190 Seerr
        // requests) while the replacement pass started a second one (Audit 2026-09-25 BROWSE-4).
        let resolved: [(Int, [JellyfinItem])] = await withTaskCancellationHandler {
            await resolveTask.value
        } onCancel: {
            resolveTask.cancel()
        }

        // A cancelled precompute must not write superseded results over the replacement run's.
        guard !Task.isCancelled else { return }
        guard !secondaries.isEmpty else {
            owner()?.applyProviderCounts(resolved, region: region)
            return
        }
        // Each secondary's studio match joins the active server's, as the combined grid does.
        var combined = resolved
        for source in secondaries {
            for index in combined.indices {
                guard !Task.isCancelled else { return }
                guard let info = providerInfos.first(where: { $0.id == combined[index].0 }) else { continue }
                let studioQuery = ItemQuery(
                    includeItemTypes: [.movie, .series],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 200,
                    studioNames: info.studioNames,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let run: @MainActor @Sendable () async -> [JellyfinItem]? = {
                    try? await source.libraryService.getItems(userID: source.userID, query: studioQuery).items
                }
                guard let studio = await Deadline.race(secondaryPassDeadline, { await run() }) ?? nil, !studio.isEmpty else { continue }
                let stamped = studio.map { item -> JellyfinItem in
                    var copy = item
                    if copy.serverID == nil { copy.serverID = source.serverID }
                    return copy
                }
                combined[index].1 = CombinedProviderMatch.mergeStudioMatches([combined[index].1, stamped])
            }
        }
        guard !Task.isCancelled else { return }
        owner()?.applyProviderCounts(combined, region: region)
    }

    private struct PassInputs {
        let pending: Bool
        let libraryService: JellyfinLibraryServiceProtocol
        let discoverService: SeerrDiscoverServiceProtocol?
        let userID: String
        /// A combined Home's other servers (Sodalite#85); empty with one server.
        let secondaries: [HomeSource]
    }

    private func providerPassInputs() -> PassInputs {
        PassInputs(pending: providerCountsComputedAt == nil, libraryService: libraryService,
                   discoverService: discoverService, userID: userID,
                   secondaries: sources.filter { !$0.isActive })
    }

    /// How long a secondary's part of a background pass may take; generous, since nobody waits on it.
    static let secondaryPassDeadline: Duration = .seconds(60)

    /// MainActor: write counts + cache + sample backdrop per provider.
    private func applyProviderCounts(_ resolved: [(Int, [JellyfinItem])], region: String) {
        for (providerID, items) in resolved {
            providerItemCounts[providerID] = items.count
            FilterCache.shared.setHomeFilterItems(
                items,
                filterKey: FilterCacheKey.Home.provider(id: providerID, region: region),
                identity: feedIdentity
            )
            // Backfill the backdrop only if the fast studio pass didn't set one; this resolver includes watch-provider matches, so it finds a sample for studio-tag-less tiles (Paramount+).
            if providerBackdrops[providerID] == nil,
               let sample = items.first,
               let url = imageService.backdropURL(for: sample, maxWidth: ImageWidth.wideCard)
                   ?? imageService.posterURL(for: sample, maxWidth: ImageWidth.wideCard) {
                providerBackdrops[providerID] = url
            }
        }

        // Latch only after a fully-written pass (see note at top).
        providerCountsComputedAt = Date()
    }

    func precomputeGenreCaches() async {
        await Self.runGenreCaches { self }
    }

    /// Pre-warms FilterCache for every on-screen genre tile so the first tap renders from disk. Mirrors the provider precompute (detached, capped, one run per session); grids still revalidate on open.
    static func runGenreCaches(_ owner: () -> HomeViewModel?) async {
        guard let inputs = owner()?.genrePassInputs() else { return }
        let genreNames = inputs.genreNames
        // A combined Home pre-warms the same merged first page its genre grid opens on (Sodalite#85).
        if inputs.sources.count > 1 {
            var resolved: [(String, [JellyfinItem])] = []
            for name in genreNames {
                guard !Task.isCancelled else { return }
                let query = ItemQuery(
                    includeItemTypes: [.movie, .series],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 50,
                    genres: [name],
                    fields: JellyfinEndpoint.homeRowFields
                )
                let pager = MergedPager(sources: MergedPager.sources(from: inputs.sources, query: query),
                                        sort: .default, pageSize: 50)
                resolved.append((name, await pager.nextPage()))
            }
            guard !Task.isCancelled else { return }
            owner()?.applyGenreCaches(resolved)
            return
        }
        let lib = inputs.libraryService
        let uid = inputs.userID

        let resolveTask = Task.detached(priority: .utility) {
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
        }
        // Mirrors precomputeProviderCounts: a detached task doesn't inherit cancellation on its own
        // (Audit 2026-09-25 BROWSE-4).
        let resolved: [(String, [JellyfinItem])] = await withTaskCancellationHandler {
            await resolveTask.value
        } onCancel: {
            resolveTask.cancel()
        }

        // A cancelled pass must not persist stale results or latch; leaving genreCachesComputedAt nil lets the next appearance run to completion.
        guard !Task.isCancelled else { return }
        owner()?.applyGenreCaches(resolved)
    }

    private struct GenrePassInputs {
        let genreNames: [String]
        let libraryService: JellyfinLibraryServiceProtocol
        let userID: String
        let sources: [HomeSource]
    }

    private func genrePassInputs() -> GenrePassInputs? {
        if genreCachesComputedAt != nil { return nil }
        // Empty-bail lets the next Home appearance retry if the genres row genuinely had nothing yet.
        let genreNames: [String] = tagRows
            .filter { $0.type == .genres }
            .flatMap { $0.tags.map(\.name) }
        if genreNames.isEmpty { return nil }
        return GenrePassInputs(genreNames: genreNames, libraryService: libraryService, userID: userID, sources: sources)
    }

    private func applyGenreCaches(_ resolved: [(String, [JellyfinItem])]) {
        // MainActor cache writes (the detached closure can't see FilterCache.shared's non-isolation under strict concurrency).
        for (name, items) in resolved where !items.isEmpty {
            FilterCache.shared.setHomeFilterItems(
                items, filterKey: FilterCacheKey.Home.genre(name: name), identity: feedIdentity
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
        tmdbMap: [String: JellyfinItem],
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
        await Self.runProviderBackdrops { self }
    }

    static func runProviderBackdrops(_ owner: () -> HomeViewModel?) async {
        guard let inputs = owner()?.providerPassInputs() else { return }
        let lib = inputs.libraryService
        let uid = inputs.userID
        // Only providers without a resolved backdrop (this pass has no per-session throttle, so without the filter it re-ran ~33 random-sample queries each loadContent just to overwrite already-resolved heroes).
        guard let resolvedIDs = owner().map({ Set($0.providerBackdrops.keys) }) else { return }
        let providers = CatalogProviders.networks.filter { !resolvedIDs.contains($0.id) }
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
                group.addTask {
                    let query = ItemQuery(
                        includeItemTypes: [.movie, .series],
                        sortBy: "Random",
                        limit: 1,
                        studioNames: provider.jellyfinStudioNames,
                        fields: JellyfinEndpoint.homeRowFields
                    )
                    let item = try? await lib.getItems(userID: uid, query: query).items.first
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
        guard !Task.isCancelled else { return }
        owner()?.applyProviderBackdrops(pairs)
    }

    private func applyProviderBackdrops(_ pairs: [(Int, JellyfinItem)]) {
        for (id, item) in pairs {
            if let url = imageService.backdropURL(for: item, maxWidth: ImageWidth.wideCard)
                ?? imageService.posterURL(for: item, maxWidth: ImageWidth.wideCard) {
                providerBackdrops[id] = url
            }
        }
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class CatalogViewModel {

    struct PagedSection {
        var items: [SeerrMedia] = []
        var currentPage: Int = 0
        var totalPages: Int = 1
        var isLoading = false

        var hasMore: Bool { currentPage < totalPages }
    }

    var trending = PagedSection()
    var popularMovies = PagedSection()
    var popularTV = PagedSection()
    var upcomingMovies = PagedSection()
    var upcomingTV = PagedSection()
    /// Genre slider lists from `/discover/genreslider/{movie,tv}`; each entry carries backdrop paths for a hero-image tile.
    var movieGenres: [SeerrGenreSlide] = []
    var tvGenres: [SeerrGenreSlide] = []
    /// Sample backdrop path per network/studio TMDB id, resolved in the background after first discover load (page-1 first-result backdrop).
    var networkBackdrops: [Int: String] = [:]
    var studioBackdrops: [Int: String] = [:]
    /// Provider tiles whose page-1 is known-empty (nothing in the region). Computed once per load (cache + live resolve) to avoid ~41 sync FilterCache disk reads per body render.
    private(set) var hiddenNetworkIDs: Set<Int> = []
    private(set) var hiddenStudioIDs: Set<Int> = []
    var myRequests: [SeerrRequest] = []
    var isLoadingMoreRequests: Bool = false
    private var myRequestsTotal: Int = 0
    private var myRequestsSkip: Int = 0
    private var myRequestsUserID: Int?

    // MARK: - Admin requests (Phase B)
    /// Via `allRequests(filter:)`; visible only when the SeerrUser has MANAGE_REQUESTS or ADMIN.
    var allRequests: [SeerrRequest] = []
    var allRequestsFilter: SeerrRequestFilter = .pending
    /// Per-filter total for chip badges; fetched in parallel on load + after each mutation, no full reload.
    var allRequestsCounts: [SeerrRequestFilter: Int] = [:]
    var isLoadingAllRequests: Bool = false
    var isLoadingMoreAllRequests: Bool = false
    /// Toast surface for `CatalogAllRequestsView`; set by the admin actions, consumed via `.onChange`, cleared after a display window.
    enum AdminRequestOutcome: Equatable {
        case approved
        case declined
        case deleted
        case updated
        case failed(message: String)
        case permissionDenied
    }
    var lastAdminRequestOutcome: AdminRequestOutcome?
    private var allRequestsTotal: Int = 0
    private var allRequestsSkip: Int = 0
    /// Bumped by every loadAllRequests; stale responses (e.g. filter-chip tap mid-flight) check it and discard instead of landing in the new filter's list.
    private var allRequestsGeneration = 0
    private let allRequestsPageSize: Int = 50

    /// Per-request enrichment by tmdbID, populated in the background after loadMyRequests so rows swap "#42" placeholders for title/year/poster as detail fetches return.
    var requestMovieDetails: [Int: SeerrMovieDetail] = [:]
    var requestTVDetails: [Int: SeerrTVDetail] = [:]

    var isLoadingDiscover = false
    var isLoadingRequests = false
    var errorMessage: String?

    private let discoverService: SeerrDiscoverServiceProtocol
    private let requestService: SeerrRequestServiceProtocol
    private let mediaService: SeerrMediaServiceProtocol
    /// Scope for the cached discover pages. Seerr's data is TMDB-shaped, but its session is per Jellyfin identity, so the pages belong to one profile like the Home tiles do. nil leaves them uncached.
    private let cacheIdentity: CacheIdentity?

    init(
        discoverService: SeerrDiscoverServiceProtocol,
        requestService: SeerrRequestServiceProtocol,
        mediaService: SeerrMediaServiceProtocol,
        cacheIdentity: CacheIdentity? = nil
    ) {
        self.discoverService = discoverService
        self.requestService = requestService
        self.mediaService = mediaService
        self.cacheIdentity = cacheIdentity
    }

    // MARK: - Request enrichment

    func title(for request: SeerrRequest) -> String? {
        guard let tmdbID = request.media?.tmdbId else { return nil }
        switch request.type {
        case .movie:  return requestMovieDetails[tmdbID]?.title
        case .tv:     return requestTVDetails[tmdbID]?.name
        case .person, .unknown: return nil
        }
    }

    func year(for request: SeerrRequest) -> String? {
        guard let tmdbID = request.media?.tmdbId else { return nil }
        switch request.type {
        case .movie:  return requestMovieDetails[tmdbID]?.displayYear
        case .tv:     return requestTVDetails[tmdbID]?.displayYear
        case .person, .unknown: return nil
        }
    }

    func posterURL(for request: SeerrRequest) -> URL? {
        guard let tmdbID = request.media?.tmdbId else { return nil }
        let path: String?
        switch request.type {
        case .movie:  path = requestMovieDetails[tmdbID]?.posterPath
        case .tv:     path = requestTVDetails[tmdbID]?.posterPath
        case .person, .unknown: path = nil
        }
        return SeerrImageURL.poster(path: path, size: .w342)
    }

    func loadDiscover() async {
        // First-page bulk load of every row in parallel; later pages via loadMore(row:) on demand.
        isLoadingDiscover = true
        errorMessage = nil
        defer { isLoadingDiscover = false }

        trending = PagedSection()
        popularMovies = PagedSection()
        popularTV = PagedSection()
        upcomingMovies = PagedSection()
        upcomingTV = PagedSection()

        do {
            async let trendingTask = discoverService.trending(page: 1)
            async let moviesTask = discoverService.popularMovies(page: 1)
            async let tvTask = discoverService.popularTV(page: 1)
            async let upcomingMoviesTask = discoverService.upcomingMovies(page: 1)
            async let upcomingTVTask = discoverService.upcomingTV(page: 1)

            let (t, m, tv, um, ut) = try await (
                trendingTask, moviesTask, tvTask,
                upcomingMoviesTask, upcomingTVTask
            )
            trending = PagedSection(items: t.results, currentPage: 1, totalPages: t.totalPages)
            popularMovies = PagedSection(items: m.results, currentPage: 1, totalPages: m.totalPages)
            popularTV = PagedSection(items: tv.results, currentPage: 1, totalPages: tv.totalPages)
            upcomingMovies = PagedSection(items: um.results, currentPage: 1, totalPages: um.totalPages)
            upcomingTV = PagedSection(items: ut.results, currentPage: 1, totalPages: ut.totalPages)
        } catch {
            errorMessage = ErrorText.user(for: error)
        }

        // Best-effort background loads; failures just leave rows plain, don't poison the discover screen.
        Task { await loadGenres() }
        Task { await loadProviderBackdrops() }
    }

    private func loadGenres() async {
        async let movieTask = try? discoverService.movieGenres()
        async let tvTask = try? discoverService.tvGenres()
        let (movie, tv) = await (movieTask, tvTask)
        if let movie { movieGenres = movie }
        if let tv { tvGenres = tv }
    }

    private func loadProviderBackdrops() async {
        // One fetch per provider/studio, doing two jobs: (1) pull a sample backdrop (page 1, default sort) for the tile hero image; (2) persist page 1 to FilterCache under the exact key CatalogDiscoverView's empty-tile-hide filter checks, so region-empty providers (Hulu/Peacock outside US, Hotstar outside India) drop on first render instead of after one tap.
        // Watch-provider streamers fetch movies + tv in parallel and merge (same shape as a tile tap, so the cache hit is exact); broadcast-only entries (ABC, NBC, CBS) fall back to the TV-network endpoint.
        let region = Locale.current.region?.identifier ?? "US"

        // Seed hide sets from cache so tiles known-empty from a prior session disappear on first render before the live resolve lands.
        var hiddenNetworks: Set<Int> = []
        for provider in CatalogProviders.networks {
            let key: String
            if let id = provider.tmdbWatchProviderID {
                key = FilterCacheKey.Catalog.streamingService(watchProviderID: id, region: region)
            } else {
                key = FilterCacheKey.Catalog.tvNetwork(id: provider.id)
            }
            if let identity = cacheIdentity,
               let cached = FilterCache.shared.catalogPage(filterKey: key, identity: identity),
               cached.items.isEmpty {
                hiddenNetworks.insert(provider.id)
            }
        }
        hiddenNetworkIDs = hiddenNetworks
        var hiddenStudios: Set<Int> = []
        for provider in CatalogProviders.studios {
            let key = FilterCacheKey.Catalog.movieStudio(id: provider.id)
            if let identity = cacheIdentity,
               let cached = FilterCache.shared.catalogPage(filterKey: key, identity: identity),
               cached.items.isEmpty {
                hiddenStudios.insert(provider.id)
            }
        }
        hiddenStudioIDs = hiddenStudios

        let results = await withTaskGroup(
            of: ProviderResolveResult.self,
            returning: [ProviderResolveResult].self
        ) { group in
            for provider in CatalogProviders.networks {
                group.addTask { [discoverService] in
                    if let watchID = provider.tmdbWatchProviderID {
                        async let moviesTask = try? discoverService.moviesByWatchProvider(
                            providerID: watchID, region: region, page: 1
                        )
                        async let tvTask = try? discoverService.tvByWatchProvider(
                            providerID: watchID, region: region, page: 1
                        )
                        let (movies, tv) = await (moviesTask, tvTask)
                        let merged = (movies?.results ?? []) + (tv?.results ?? [])
                        let totalPages = max(movies?.totalPages ?? 0, tv?.totalPages ?? 0)
                        var backdrop = merged.first(where: { $0.backdropPath != nil })?.backdropPath
                        if backdrop == nil {
                            // Fallback: TV-network endpoint sometimes carries different items.
                            let fallback = try? await discoverService.tvByNetwork(
                                networkID: provider.id, page: 1
                            )
                            backdrop = fallback?.results.first(where: { $0.backdropPath != nil })?.backdropPath
                        }
                        return ProviderResolveResult(
                            kind: .network,
                            displayID: provider.id,
                            cacheKey: FilterCacheKey.Catalog.streamingService(
                                watchProviderID: watchID, region: region
                            ),
                            items: merged,
                            totalPages: max(totalPages, 1),
                            backdrop: backdrop,
                            fetchFailed: movies == nil && tv == nil
                        )
                    } else {
                        let result = try? await discoverService.tvByNetwork(
                            networkID: provider.id, page: 1
                        )
                        return ProviderResolveResult(
                            kind: .network,
                            displayID: provider.id,
                            cacheKey: FilterCacheKey.Catalog.tvNetwork(id: provider.id),
                            items: result?.results ?? [],
                            totalPages: max(result?.totalPages ?? 1, 1),
                            backdrop: result?.results.first(where: { $0.backdropPath != nil })?.backdropPath,
                            fetchFailed: result == nil
                        )
                    }
                }
            }
            for provider in CatalogProviders.studios {
                group.addTask { [discoverService] in
                    let result = try? await discoverService.moviesByStudio(
                        studioID: provider.id, page: 1
                    )
                    return ProviderResolveResult(
                        kind: .studio,
                        displayID: provider.id,
                        cacheKey: FilterCacheKey.Catalog.movieStudio(id: provider.id),
                        items: result?.results ?? [],
                        totalPages: max(result?.totalPages ?? 1, 1),
                        backdrop: result?.results.first(where: { $0.backdropPath != nil })?.backdropPath,
                        fetchFailed: result == nil
                    )
                }
            }
            var collected: [ProviderResolveResult] = []
            for await item in group { collected.append(item) }
            return collected
        }

        // MainActor sweep: write cache + backdrop once resolved (keeping FilterCache writes off the detached closures dodges async-isolation).
        for result in results {
            // A failed fetch must not persist as a valid empty page (would hide the tile until a successful revisit) nor flip the hide sets.
            guard !result.fetchFailed else { continue }
            if let identity = cacheIdentity {
                FilterCache.shared.setCatalogPage(
                    result.items,
                    totalPages: result.totalPages,
                    filterKey: result.cacheKey,
                    identity: identity
                )
            }
            switch result.kind {
            case .network:
                if result.items.isEmpty {
                    hiddenNetworkIDs.insert(result.displayID)
                } else {
                    hiddenNetworkIDs.remove(result.displayID)
                }
            case .studio:
                if result.items.isEmpty {
                    hiddenStudioIDs.insert(result.displayID)
                } else {
                    hiddenStudioIDs.remove(result.displayID)
                }
            }
            if let backdrop = result.backdrop {
                switch result.kind {
                case .network: networkBackdrops[result.displayID] = backdrop
                case .studio: studioBackdrops[result.displayID] = backdrop
                }
            }
        }
    }

    private struct ProviderResolveResult: Sendable {
        let kind: ProviderKind
        let displayID: Int
        let cacheKey: String
        let items: [SeerrMedia]
        let totalPages: Int
        let backdrop: String?
        let fetchFailed: Bool
    }

    private enum ProviderKind { case network, studio }

    enum DiscoverRow {
        case trending, movies, tv, upcomingMovies, upcomingTV
    }

    /// Load the next page for one row (on scroll-near-end). Dedupes against current items: Seerr repeats entries across adjacent pages when the list shifts.
    func loadMore(row: DiscoverRow) async {
        var section = section(for: row)
        guard !section.isLoading, section.hasMore else { return }

        section.isLoading = true
        updateSection(row, to: section)

        do {
            let nextPage = section.currentPage + 1
            let result: SeerrDiscoverResult
            switch row {
            case .trending:
                result = try await discoverService.trending(page: nextPage)
            case .movies:
                result = try await discoverService.popularMovies(page: nextPage)
            case .tv:
                result = try await discoverService.popularTV(page: nextPage)
            case .upcomingMovies:
                result = try await discoverService.upcomingMovies(page: nextPage)
            case .upcomingTV:
                result = try await discoverService.upcomingTV(page: nextPage)
            }

            let existingKeys = Set(section.items.map(\.stableKey))
            let additions = result.results.filter { !existingKeys.contains($0.stableKey) }

            section.items.append(contentsOf: additions)
            section.currentPage = result.page
            section.totalPages = result.totalPages
            section.isLoading = false
            updateSection(row, to: section)
        } catch {
            section.isLoading = false
            updateSection(row, to: section)
            // Swallow pagination errors; page 1 stays visible, a mid-scroll banner would jar.
        }
    }

    func loadMyRequests(userID: Int) async {
        isLoadingRequests = true
        errorMessage = nil
        myRequestsUserID = userID
        myRequestsSkip = 0
        myRequestsTotal = 0
        defer { isLoadingRequests = false }

        do {
            let result = try await requestService.myRequests(
                userID: userID,
                take: 50,
                skip: 0
            )
            myRequests = result.results
            myRequestsTotal = result.pageInfo.results
            myRequestsSkip = result.results.count
            // Background enrichment; list renders immediately with placeholders, swaps to real metadata as fetches return.
            Task { await enrichRequestMetadata(for: result.results) }
        } catch {
            errorMessage = ErrorText.user(for: error)
        }
    }

    /// Next page for "My Requests" (mirrors loadMoreAllRequests): prolific users have more than one
    /// page, so the tab must paginate instead of capping at the first 50.
    func loadMoreMyRequests() async {
        guard let userID = myRequestsUserID,
              myRequests.count < myRequestsTotal,
              !isLoadingMoreRequests,
              !isLoadingRequests else { return }
        isLoadingMoreRequests = true
        defer { isLoadingMoreRequests = false }

        do {
            let result = try await requestService.myRequests(
                userID: userID,
                take: 50,
                skip: myRequestsSkip
            )
            // Dedupe against the visible list: Seerr repeats records across adjacent pages when status counts shift between fetches.
            let existing = Set(myRequests.map(\.id))
            let additions = result.results.filter { !existing.contains($0.id) }
            myRequests.append(contentsOf: additions)
            myRequestsTotal = result.pageInfo.results
            myRequestsSkip += result.results.count
            Task { await enrichRequestMetadata(for: additions) }
        } catch {
            // Mid-scroll error stays silent; the visible page remains.
        }
    }

    private func enrichRequestMetadata(for requests: [SeerrRequest]) async {
        // Dedupe not-yet-enriched tmdbIDs, then fetch details in parallel; row bodies read through the dicts and update as entries land.
        var movieIDs = Set<Int>()
        var tvIDs = Set<Int>()
        for request in requests {
            guard let tmdbID = request.media?.tmdbId else { continue }
            switch request.type {
            case .movie:
                if requestMovieDetails[tmdbID] == nil { movieIDs.insert(tmdbID) }
            case .tv:
                if requestTVDetails[tmdbID] == nil { tvIDs.insert(tmdbID) }
            case .person, .unknown:
                break
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for id in movieIDs {
                group.addTask { [weak self] in
                    guard let detail = try? await self?.mediaService.movieDetail(tmdbID: id) else { return }
                    await MainActor.run {
                        self?.requestMovieDetails[id] = detail
                    }
                }
            }
            for id in tvIDs {
                group.addTask { [weak self] in
                    guard let detail = try? await self?.mediaService.tvDetail(tmdbID: id) else { return }
                    await MainActor.run {
                        self?.requestTVDetails[id] = detail
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func section(for row: DiscoverRow) -> PagedSection {
        switch row {
        case .trending: trending
        case .movies: popularMovies
        case .tv: popularTV
        case .upcomingMovies: upcomingMovies
        case .upcomingTV: upcomingTV
        }
    }

    private func updateSection(_ row: DiscoverRow, to new: PagedSection) {
        switch row {
        case .trending: trending = new
        case .movies: popularMovies = new
        case .tv: popularTV = new
        case .upcomingMovies: upcomingMovies = new
        case .upcomingTV: upcomingTV = new
        }
    }

    // MARK: - Admin requests

    /// Jellyseerr exposes no server-side "declined" request filter (its filters are all/pending/approved/
    /// available/processing/unavailable/failed); declined requests only come back under `all`. So the
    /// Declined tab queries `all` on the server and keeps status == .declined client-side. Works
    /// regardless of the server's filter support.
    private func serverFilter(for filter: SeerrRequestFilter) -> SeerrRequestFilter {
        filter == .declined ? .all : filter
    }

    private func applyClientFilter(_ requests: [SeerrRequest], for filter: SeerrRequestFilter) -> [SeerrRequest] {
        filter == .declined ? requests.filter { $0.status == .declined } : requests
    }

    func loadAllRequests() async {
        // Supersede via generation, not an `!isLoadingAllRequests` guard: a chip tap during the initial load otherwise no-op'd the new filter and the in-flight response self-dropped, leaving an empty list.
        allRequestsGeneration &+= 1
        let generation = allRequestsGeneration
        allRequestsSkip = 0
        allRequests = []
        allRequestsTotal = 0
        isLoadingAllRequests = true
        defer {
            if generation == allRequestsGeneration { isLoadingAllRequests = false }
        }

        let filter = allRequestsFilter
        let server = serverFilter(for: filter)
        do {
            // Client-side filters (declined) may find no match on the first raw page, so keep pulling
            // raw pages until at least one match lands or the source is exhausted. `allRequestsSkip`
            // (raw cursor) drives has-more; `allRequests` holds only the matches.
            repeat {
                let result = try await requestService.allRequests(
                    filter: server,
                    take: allRequestsPageSize,
                    skip: allRequestsSkip
                )
                guard generation == allRequestsGeneration else { return }
                let matches = applyClientFilter(result.results, for: filter)
                allRequests.append(contentsOf: matches)
                allRequestsTotal = result.pageInfo.results
                allRequestsSkip += result.results.count
                Task { await enrichRequestMetadata(for: matches) }
                if result.results.isEmpty { break }
            } while filter == .declined && allRequests.isEmpty && allRequestsSkip < allRequestsTotal
        } catch {
            guard generation == allRequestsGeneration else { return }
            errorMessage = ErrorText.user(for: error)
        }
    }

    func loadMoreAllRequests() async {
        // Has-more is driven by the raw cursor vs the server total, not the visible count: with a
        // client-side filter (declined) the visible list stays smaller than the raw total, and dedupe
        // can shrink it below the cursor for normal filters too.
        guard allRequestsSkip < allRequestsTotal,
              !isLoadingMoreAllRequests,
              !isLoadingAllRequests else { return }
        isLoadingMoreAllRequests = true
        defer { isLoadingMoreAllRequests = false }

        // Generation snapshot: a reload (filter switch or refresh) can reset the list mid-flight (separate loading flags), so this page's response must not append.
        let generation = allRequestsGeneration
        let filter = allRequestsFilter
        let server = serverFilter(for: filter)
        do {
            // For a client-side filter, keep pulling raw pages until this call adds at least one new
            // match or the source is exhausted, so a scroll-triggered load never appears to do nothing.
            repeat {
                let result = try await requestService.allRequests(
                    filter: server,
                    take: allRequestsPageSize,
                    skip: allRequestsSkip
                )
                guard generation == allRequestsGeneration else { return }
                if result.results.isEmpty { break }
                // Dedupe against the visible list: Seerr repeats records across adjacent pages when status counts shift between fetches.
                let existing = Set(allRequests.map(\.id))
                let additions = applyClientFilter(result.results, for: filter).filter { !existing.contains($0.id) }
                allRequests.append(contentsOf: additions)
                allRequestsTotal = result.pageInfo.results
                allRequestsSkip += result.results.count
                Task { await enrichRequestMetadata(for: additions) }
                if !additions.isEmpty { break }
            } while filter == .declined && allRequestsSkip < allRequestsTotal
        } catch {
            // Mid-scroll error stays silent; visible page remains, retry by switching filters.
        }
    }

    func setAllRequestsFilter(_ filter: SeerrRequestFilter) async {
        guard allRequestsFilter != filter else { return }
        allRequestsFilter = filter
        await loadAllRequests()
    }

    /// Per-filter `pageInfo.results` counts via `take=0` (no array transferred) for the chip badges; failures keep existing values (stale over blanked).
    func refreshAllRequestsCounts() async {
        // No `declined` count: Jellyseerr has no server-side declined filter, so a take=0 count query
        // is unreliable. The chip shows no number rather than a wrong one (deriving it would mean
        // scanning the whole `all` list client-side).
        async let pending  = try? requestService.allRequests(filter: .pending,  take: 0, skip: 0)
        async let approved = try? requestService.allRequests(filter: .approved, take: 0, skip: 0)
        async let all      = try? requestService.allRequests(filter: .all,      take: 0, skip: 0)
        let results = await (pending, approved, all)
        if let p = results.0 { allRequestsCounts[.pending]  = p.pageInfo.results }
        if let a = results.1 { allRequestsCounts[.approved] = a.pageInfo.results }
        if let x = results.2 { allRequestsCounts[.all]      = x.pageInfo.results }
        // Nudge the Catalog tab badge: this runs on queue load and after every admin mutation.
        NotificationCenter.default.post(name: .seerrPendingRequestsShouldRefresh, object: nil)
    }

    // MARK: - Admin mutations

    func approveRequest(_ request: SeerrRequest) async {
        await runAdminMutation(originalRequest: request, outcome: .approved) {
            try await self.requestService.approveRequest(requestID: request.id)
        }
    }

    func declineRequest(_ request: SeerrRequest) async {
        await runAdminMutation(originalRequest: request, outcome: .declined) {
            try await self.requestService.declineRequest(requestID: request.id)
        }
    }

    func deleteRequest(_ request: SeerrRequest) async {
        // Optimistic remove; restore on failure so the user can retry.
        let snapshot = allRequests
        allRequests.removeAll { $0.id == request.id }
        do {
            try await requestService.deleteRequest(requestID: request.id)
            lastAdminRequestOutcome = .deleted
            await refreshAllRequestsCounts()
        } catch let error as APIError where error.isUnauthorized {
            allRequests = snapshot
            lastAdminRequestOutcome = .permissionDenied
            // No local permission refresh: the 403 toast is the signal; next session restore reloads activeSeerrUser (AppRouter hides the tab if the revoke sticks).
        } catch let error as APIError where error.isNotFound {
            // Already gone server-side, keep the optimistic remove.
            lastAdminRequestOutcome = .deleted
            await refreshAllRequestsCounts()
        } catch {
            allRequests = snapshot
            lastAdminRequestOutcome = .failed(message: ErrorText.user(for: error))
        }
    }

    func updateRequest(_ request: SeerrRequest, body: SeerrRequestUpdateBody) async -> SeerrRequest? {
        do {
            let updated = try await requestService.updateRequest(
                requestID: request.id,
                body: body
            )
            replaceRequest(updated)
            lastAdminRequestOutcome = .updated
            return updated
        } catch let error as APIError where error.isUnauthorized {
            lastAdminRequestOutcome = .permissionDenied
            // No local permission refresh: the 403 toast is the signal; next session restore reloads activeSeerrUser (AppRouter hides the tab if the revoke sticks).
            return nil
        } catch let error as APIError where error.isNotFound {
            await loadAllRequests()
            return nil
        } catch {
            lastAdminRequestOutcome = .failed(message: ErrorText.user(for: error))
            return nil
        }
    }

    /// Shared approve/decline body: optimistically replaces the row with the server response, drops it if the new status no longer matches the active filter, restores on failure for retry.
    private func runAdminMutation(
        originalRequest: SeerrRequest,
        outcome: AdminRequestOutcome,
        action: @escaping () async throws -> SeerrRequest
    ) async {
        let snapshot = allRequests
        do {
            let updated = try await action()
            replaceRequest(updated)
            if !filterMatches(updated, filter: allRequestsFilter) {
                allRequests.removeAll { $0.id == updated.id }
            }
            lastAdminRequestOutcome = outcome
            await refreshAllRequestsCounts()
        } catch let error as APIError where error.isUnauthorized {
            allRequests = snapshot
            lastAdminRequestOutcome = .permissionDenied
            // No local permission refresh: the 403 toast is the signal; next session restore reloads activeSeerrUser (AppRouter hides the tab if the revoke sticks).
        } catch let error as APIError where error.isNotFound {
            // Stale row (another admin already changed it); silent reload of the current filter drops it.
            allRequests = snapshot
            await loadAllRequests()
        } catch {
            allRequests = snapshot
            lastAdminRequestOutcome = .failed(message: ErrorText.user(for: error))
        }
    }

    private func replaceRequest(_ updated: SeerrRequest) {
        if let idx = allRequests.firstIndex(where: { $0.id == updated.id }) {
            allRequests[idx] = updated
        }
    }

    private func filterMatches(_ request: SeerrRequest, filter: SeerrRequestFilter) -> Bool {
        switch filter {
        case .all:      return true
        case .pending:  return request.status == .pendingApproval
        case .approved: return request.status == .approved
        case .declined: return request.status == .declined
        }
    }
}

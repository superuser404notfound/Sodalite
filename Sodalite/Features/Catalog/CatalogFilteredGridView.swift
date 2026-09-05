import SwiftUI

/// Paged vertical grid of SeerrMedia for a single CatalogFilter (genre, network, studio); same pagination pattern as the discover rows.
struct CatalogFilteredGridView: View {
    let filter: CatalogFilter
    /// Session the cached page belongs to; nil leaves this grid uncached. Seerr's pages are TMDB-shaped but its session is per Jellyfin identity, so they scope like the Home tiles.
    let cacheIdentity: CacheIdentity?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var items: [SeerrMedia]
    @State private var page: Int
    @State private var totalPages: Int
    @State private var isLoadingMore = false
    /// Background page-1 revalidation flag, separate from `isLoadingMore` so silent stale-while-revalidate paints no spinner over the already-visible cached grid.
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var selectedMedia: SeerrMedia?

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: metrics.gridMinimum), spacing: metrics.gridSpacing)]
    }

    init(filter: CatalogFilter, cacheIdentity: CacheIdentity?) {
        self.filter = filter
        self.cacheIdentity = cacheIdentity
        // Hydrate from FilterCache during init so the first body render paints the cached grid; doing it in `.task(id:)` shows one empty frame, read as a loading flash on every tap.
        if let cacheIdentity,
           let cached = FilterCache.shared.catalogPage(filterKey: filter.cacheKey, identity: cacheIdentity) {
            _items = State(initialValue: cached.items)
            _page = State(initialValue: 1)
            _totalPages = State(initialValue: cached.totalPages)
        } else {
            _items = State(initialValue: [])
            _page = State(initialValue: 0)
            _totalPages = State(initialValue: 1)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(filter.displayName)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.horizontal, metrics.gridInset)
                    .padding(.top, 40)

                if items.isEmpty && (isLoadingMore || isRefreshing) {
                    loadingState
                } else if let errorMessage, items.isEmpty {
                    errorState(message: errorMessage)
                } else if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                        // stableKey not id: TMDB ids collide across movie/tv and streaming-service grids concatenate both result sets.
                        ForEach(items, id: \.stableKey) { media in
                            FocusableCard(
                                action: { selectedMedia = media }
                            ) { focused in
                                SeerrMediaCard(media: media, isFocused: focused)
                            }
                            .onAppear {
                                if shouldPaginate(after: media) {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, metrics.gridInset)
                    .padding(.vertical, 16)

                    if isLoadingMore && !items.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .hidesShellTabBar()
        .navigationDestination(item: $selectedMedia) { media in
            CatalogDetailView(media: media)
                .detailCoverPush()
        }
        .task(id: filter) {
            errorMessage = nil
            // Grid already on screen (hydrated in init); just fire the background page-1 refresh.
            await refreshFirstPage()
        }
    }

    // MARK: - Pagination

    private func shouldPaginate(after media: SeerrMedia) -> Bool {
        guard !isLoadingMore, page < totalPages else { return false }
        // Trigger within ~12 items of the end so the fetch lands before the user hits bottom.
        let key = media.stableKey
        guard let index = items.firstIndex(where: { $0.stableKey == key }) else {
            return false
        }
        return index >= items.count - 12
    }

    /// Re-fetches page 1 on appearance to pick up lineup rotation and updates the cache; pages 2+ still go through `loadMore`.
    private func refreshFirstPage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let result = try await fetchPage(1)
            // Replace only on actual change: wholesale assignment re-evaluates every cell even with identical ids, read as a reload flash. Compare stableKeys to leave the view tree untouched when nothing rotated.
            let oldKeys = items.map(\.stableKey)
            let newKeys = result.results.map(\.stableKey)
            if page > 1 {
                // User already paginated past page 1 during this in-flight refresh; a wholesale replace would yank pages 2+ from under their focus, so only replace when page 1 itself rotated.
                if oldKeys.prefix(newKeys.count) != ArraySlice(newKeys) {
                    items = result.results
                    page = 1
                }
                totalPages = result.totalPages
            } else {
                if oldKeys != newKeys {
                    items = result.results
                }
                page = 1
                totalPages = result.totalPages
            }
            errorMessage = nil
            if let cacheIdentity {
                FilterCache.shared.setCatalogPage(
                    result.results,
                    totalPages: result.totalPages,
                    filterKey: filter.cacheKey,
                    identity: cacheIdentity
                )
            }
        } catch {
            // Keep the cache-hydrated grid rather than wiping on a transient network blip.
            if items.isEmpty {
                errorMessage = ErrorText.user(for: error)
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, page < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let nextPage = page + 1
        do {
            let result = try await fetchPage(nextPage)
            let existing = Set(items.map(\.stableKey))
            let additions = result.results.filter { !existing.contains($0.stableKey) }
            items.append(contentsOf: additions)
            page = result.page
            totalPages = result.totalPages
        } catch {
            errorMessage = ErrorText.user(for: error)
        }
    }

    /// Dispatches to the filter's discover endpoint(s). Streaming-service fans out movies + tv in parallel and merges; others are single-endpoint.
    private func fetchPage(_ page: Int) async throws -> SeerrDiscoverResult {
        switch filter {
        case .movieGenre(let id, _):
            return try await dependencies.seerrDiscoverService
                .moviesByGenre(genreID: id, page: page)
        case .tvGenre(let id, _):
            return try await dependencies.seerrDiscoverService
                .tvByGenre(genreID: id, page: page)
        case .movieStudio(let id, _):
            return try await dependencies.seerrDiscoverService
                .moviesByStudio(studioID: id, page: page)
        case .tvNetwork(let id, _):
            return try await dependencies.seerrDiscoverService
                .tvByNetwork(networkID: id, page: page)
        case .streamingService(let providerID, _, let region):
            async let moviesTask = dependencies.seerrDiscoverService
                .moviesByWatchProvider(providerID: providerID, region: region, page: page)
            async let tvTask = dependencies.seerrDiscoverService
                .tvByWatchProvider(providerID: providerID, region: region, page: page)
            let (movies, tv) = try await (moviesTask, tvTask)
            return SeerrDiscoverResult(
                page: page,
                totalPages: max(movies.totalPages, tv.totalPages),
                totalResults: movies.totalResults + tv.totalResults,
                results: movies.results + tv.results
            )
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            // Focusable Button so Menu pops back instead of quitting (a text-only state has nothing to land on).
            Button { dismiss() } label: {
                Text("common.back")
                    .font(.body)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    /// Zero-match state (e.g. a streaming-service tile with no titles in the region). Same focusable back-button as `errorState` so Menu pops back.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("search.empty.noResults")
                .foregroundStyle(.secondary)
            Button { dismiss() } label: {
                Text("common.back")
                    .font(.body)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    /// Loading state with an invisible focusable button so a Menu press during the initial fetch pops back instead of quitting the app.
    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Button("") { dismiss() }
                .opacity(0)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }
}

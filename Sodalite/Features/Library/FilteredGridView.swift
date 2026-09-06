import SwiftUI

/// Watch-status narrowing for the library grids (Sodalite#17). Maps to Jellyfin's `Filters`; `.all` sends nothing (the default).
enum WatchStatusFilter: String, CaseIterable, Hashable {
    case all
    case unwatched
    case watched

    /// Jellyfin `Filters` value, nil for the unfiltered default.
    var jellyfinFilter: String? {
        switch self {
        case .all: nil
        case .unwatched: "IsUnplayed"
        case .watched: "IsPlayed"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all: "library.filter.all"
        case .unwatched: "library.filter.unwatched"
        case .watched: "library.filter.watched"
        }
    }
}

struct FilteredGridView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var items: [JellyfinItem]
    @State private var isLoading: Bool
    @State private var selectedItem: JellyfinItem?
    @State private var showPlayer = false
    @State private var playItem: JellyfinItem?
    @State private var playQueue: [JellyfinItem] = []
    @State private var watchFilter: WatchStatusFilter = .all
    /// Hydrated from LibrarySortStore in init, not .task: the cache hydration below depends on it (a
    /// non-default sort must not paint the cached default order), and .task runs a frame too late.
    @State private var sort: LibrarySort
    @State private var showSortSheet = false
    /// Presents the single-field sheet that fills the server's empty URL slot (iOS only; tvOS has
    /// no URL editor).
    @State private var showAddURLSheet = false
    @FocusState private var focusedItemID: String?
    @Environment(\.dismiss) private var dismiss

    /// Distinguishes "fetch failed, nothing to show" (retry state) from "server says empty".
    @State private var loadFailed = false
    /// Stamped per loadItems run, checked after each await so a superseded run (filter flip, retry) can't write over the newer one.
    @State private var loadGeneration = 0
    /// TotalRecordCount from the last phase-1 response, drives load-more; nil until the first fetch lands.
    @State private var totalRecordCount: Int?
    @State private var isLoadingMore = false
    /// True once loadMore appended a page this cycle; the refresh keeps appended pages instead of truncating to page 1. Explicit flag, not a prefix heuristic: a page-1 server reorder breaks prefix comparison.
    @State private var didPaginate = false
    /// Raw server cursor for pagination, advanced by the fetched count (NOT items.count): a page that
    /// returns only already-known ids (SortName ties, library mutated between fetches) must still move
    /// the cursor past the overlapping window, else it re-requests the same offset forever and the tail
    /// never loads.
    @State private var nextStartIndex = 0
    /// Set once the server returns a short/empty page; stops paginating even when dedup leaves
    /// items.count short of totalRecordCount.
    @State private var reachedEnd = false

    let title: String
    let query: ItemQuery
    /// TMDB watch-provider id: after the studio filter resolves, augment with Jellyseerr's "streaming now" list so studio-tag-less titles surface under their service (Modern Family on Disney+).
    let smartProviderID: Int?
    let smartProviderRegion: String?
    /// Where this grid's results are cached: key + the session that fetched them. nil disables caching entirely; the two never travel apart, so a key cannot be written unscoped.
    let cacheScope: FilterCacheScope?
    /// Where this grid's sort choice is stored (Sodalite#78); nil hides the control. Streaming-provider
    /// tiles pass nil: their list is merged client-side from two phases, so a server sort would only
    /// order half of it.
    let sortScope: LibrarySortScope?
    /// Playlists grid only: Jellyfin answers IncludeItemTypes=Playlist with audio and video playlists
    /// alike, and `MediaType` on a Playlist is a computed property, so no server-side filter holds
    /// across versions (Sodalite#73). A music playlist has no detail screen to open, so it is dropped
    /// here instead. nil-tolerant: an unknown media type stays visible.
    let hidesAudioPlaylists: Bool

    init(
        title: String,
        query: ItemQuery,
        smartProviderID: Int? = nil,
        smartProviderRegion: String? = nil,
        cacheScope: FilterCacheScope? = nil,
        sortScope: LibrarySortScope? = nil,
        hidesAudioPlaylists: Bool = false
    ) {
        self.title = title
        self.query = query
        self.smartProviderID = smartProviderID
        self.smartProviderRegion = smartProviderRegion
        self.cacheScope = cacheScope
        self.sortScope = sortScope
        self.hidesAudioPlaylists = hidesAudioPlaylists
        let storedSort = sortScope.map(LibrarySortStore.sort) ?? .default
        _sort = State(initialValue: storedSort)
        // Hydrate from FilterCache in init so the first render paints the cached grid; doing it in .task means a frame with isLoading=true first (the brief loading flash on every tap).
        // Only the default sort: the cache holds one order per key, so a custom sort would paint the
        // alphabetical list and then reshuffle it once the fetch lands.
        if storedSort == .default,
           let scope = cacheScope,
           let cached = FilterCache.shared.homeFilterItems(filterKey: scope.key, identity: scope.identity),
           !cached.isEmpty {
            _items = State(initialValue: cached)
            _isLoading = State(initialValue: false)
        } else {
            _items = State(initialValue: [])
            _isLoading = State(initialValue: true)
        }
    }

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        ScrollView {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.gridInset)
                .padding(.top, 20)

            // Watch-status filter (Sodalite#17). Native segmented
            // control per the app's section-picker convention
            // (Catalog tabs, Live TV Guide/Recordings).
            Picker("", selection: $watchFilter) {
                ForEach(WatchStatusFilter.allCases, id: \.self) { filter in
                    Text(filter.localizedTitle).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, metrics.gridInset)
            .padding(.top, 8)

            HStack {
                GlassActionButton(
                    title: "action.shuffle",
                    systemImage: "shuffle",
                    action: {
                        guard let userID = appState.activeUser?.id else { return }
                        // Shows libraries shuffle episodes across the whole
                        // library; everything else keeps its own item types.
                        var types = query.includeItemTypes ?? [.movie]
                        if types.contains(.series) { types = [.episode] }
                        Task {
                            let queue = await VideoShuffleQueue.build(
                                parentID: query.parentID,
                                baseQuery: query,
                                itemTypes: types,
                                service: dependencies.jellyfinLibraryService,
                                userID: userID
                            )
                            guard let first = queue.first else { return }
                            playItem = first
                            playQueue = queue
                            showPlayer = true
                        }
                    }
                )
                if sortScope != nil {
                    GlassActionButton(
                        title: "library.sort.action",
                        systemImage: "arrow.up.arrow.down",
                        action: { showSortSheet = true }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, metrics.gridInset)
            .padding(.top, 8)

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    // Focusable element so Menu button works during loading
                    Button("") { dismiss() }
                        .opacity(0)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            } else if let state = unreachableState {
                ServerUnreachableView(
                    state: state,
                    serverName: appState.activeServer?.name ?? "",
                    onAddExternalAddress: ServerUnreachableView.addExternalAddressAction(
                        state: state,
                        server: appState.activeServer,
                        present: { showAddURLSheet = true }
                    ),
                    onRetry: { await retry() }
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("library.empty.message")
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
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: metrics.gridMinimum), spacing: metrics.gridSpacing)
                ], spacing: metrics.gridSpacing) {
                    ForEach(items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            MediaCard(
                                item: item,
                                imageURL: dependencies.jellyfinImageService.posterURL(for: item),
                                isFocused: focusedItemID == item.id
                            )
                        }
                        .buttonStyle(GridCardButtonStyle())
                        .focused($focusedItemID, equals: item.id)
                        .onAppear { loadMoreIfNeeded(after: item) }
                    }
                }
                .padding(.horizontal, metrics.gridInset)
                .padding(.vertical, 40)
                .enrichesPosterBadges(items)

                if isLoadingMore {
                    ProgressView()
                        .padding(.bottom, 40)
                }
            }
        }
        .overlay {
            if let userID = appState.activeUser?.id {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? playItem : nil,
                    startFromBeginning: true,
                    playbackService: dependencies.jellyfinPlaybackService,
                    itemService: dependencies.jellyfinItemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: userID),
                    cachedPlaybackInfo: nil,
                    preferredMediaSourceID: nil,
                    playQueue: playQueue
                )
                .allowsHitTesting(false)
            }
        }
        .onChange(of: appState.requestPlayerDismissal) { _, _ in
            if showPlayer { showPlayer = false }
        }
        .navigationBarHidden(true)
        .hidesShellTabBar()
        .navigationDestination(item: $selectedItem) { item in
            DetailRouterView(item: item)
                .detailCoverPush()
        }
        .sheet(isPresented: $showSortSheet) {
            LibrarySortSheet(
                selection: sort,
                tintColor: dependencies.appearancePreferences.effectiveTint(
                    isSupporter: dependencies.storeKitService.isSupporter
                ),
                onSelect: { newSort in
                    sort = newSort
                    guard let sortScope else { return }
                    LibrarySortStore.setSort(newSort, scope: sortScope)
                    // CloudSyncService listens for this and marks the server record dirty. Deliberately
                    // not .homeConfigDidChange: that one also makes HomeView reload every row, which a
                    // sort change inside one grid has no reason to do.
                    NotificationCenter.default.post(name: .librarySortDidChange, object: nil)
                }
            )
        }
        // The fix for an off-network server, offered where the failure is (Sodalite#122).
        .addExternalAddressSheet(isPresented: $showAddURLSheet)
        .onChange(of: reloadKey) { _, _ in
            // Drop the now-mismatched grid immediately (else stale-while-revalidate briefly shows watched items under "Unwatched", or the old order under a new sort); the keyed task refetches.
            items = []
            isLoading = true
            loadFailed = false
            totalRecordCount = nil
            didPaginate = false
            nextStartIndex = 0
            reachedEnd = false
        }
        .task(id: reloadKey) {
            await loadItems()
            // No forced first-item focus: the Picker (always rendered) plus each state's own focusable anchor means back never closes the app. Nudging to item 0 was harmful: a Picker switch clears items, dropping focusedItemID to nil, and this keyed task would yank focus off the Picker mid-browse.
        }
    }

    /// What the grid shows instead of a grid, off the same verdict Home reads (Sodalite#122).
    ///
    /// This screen used to render "Couldn't reach your server. Check the connection and try again.",
    /// the exact sentence #122 removed from Home and did not reach here. Off Wi-Fi it is not merely
    /// vague, it is a wrong lead: the connection is fine, the address is the problem, and it sends
    /// the reader to restart a router they are nowhere near.
    private var unreachableState: ServerReachability? {
        appState.serverReachability.blockingState(
            hasContent: !items.isEmpty,
            loadFailedEntirely: loadFailed
        )
    }

    /// Re-probe before re-fetching, else the reload runs against the same stale verdict and paints
    /// this screen straight back.
    ///
    /// Only the probe is awaited, and no loading flag is raised. The fetch behind it needs the full
    /// round of request timeouts to give up on a server that is still down, so a Retry that waited
    /// for it would spin for minutes, which is the bug this screen exists to remove.
    private func retry() async {
        await dependencies.retryAfterFailure()
        Task { await loadItems() }
    }

    /// Phase-1 (studio match), kept separate from `items` so the augment refresh rebuilds the merged grid without re-running the studio query.
    @State private var studioItems: [JellyfinItem] = []

    /// Anything that invalidates the loaded page set: both a filter flip and a sort change need the
    /// same reset (grid, pagination cursor, end marker) before the keyed task refetches.
    private struct ReloadKey: Equatable {
        let filter: WatchStatusFilter
        let sort: LibrarySort
    }

    private var reloadKey: ReloadKey { ReloadKey(filter: watchFilter, sort: sort) }

    /// Narrowing the server cannot express. `totalRecordCount` stays the raw server count, so a page
    /// can come back empty after filtering; `reachedEnd` (short page) closes the pagination anyway.
    private func browsable(_ items: [JellyfinItem]) -> [JellyfinItem] {
        hidesAudioPlaylists ? items.filter { !$0.isAudioPlaylist } : items
    }

    private func loadItems() async {
        guard let userID = appState.activeUser?.id else { return }
        loadGeneration += 1
        let generation = loadGeneration

        // Watch-status filter applies server-side to BOTH phases (phase 1 + the full-library map phase 2 resolves against), so phase 2 can't re-introduce filtered-out items.
        var effectiveQuery = sort.applied(to: query)
        if let filter = watchFilter.jellyfinFilter {
            effectiveQuery.filters = [filter]
        }
        let isWatchFiltered = watchFilter != .all

        // nil = fetch failed/cancelled, distinct from "server empty": a failure must never replace the grid or persist into FilterCache as a valid empty (that poisoned the cache and killed instant-paint until the next pre-warm).
        async let studioMatchTask: JellyfinItemsResponse? = { [effectiveQuery] in
            try? await dependencies.jellyfinLibraryService.getItems(
                userID: userID, query: effectiveQuery
            )
        }()

        async let allLibraryTask: [JellyfinItem]? = { [watchFilterValue = watchFilter.jellyfinFilter] in
            guard smartProviderID != nil else { return [] }
            // Fetch the whole library in one shot, not per-id AnyProviderIdEquals lookups: robust against Jellyfin version quirks and amortised across every TMDB id.
            var allQuery = ItemQuery(
                includeItemTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 10000,
                // Only tmdbID and the image tags are read off this scan. Same set as the identical
                // query in HomeViewModel+Precompute; detailFields over a whole library was the
                // single biggest request the app could issue (Sodalite#68).
                fields: JellyfinEndpoint.homeRowFields + ",ProviderIds"
            )
            if let filter = watchFilterValue {
                allQuery.filters = [filter]
            }
            return try? await dependencies.jellyfinLibraryService.getItems(
                userID: userID, query: allQuery
            ).items
        }()

        let phase1Response = await studioMatchTask
        let allItems = await allLibraryTask

        // Backed out (Menu/detail tap) or superseded: leave all state alone.
        guard !Task.isCancelled, generation == loadGeneration else { return }

        guard let phase1Response else {
            // Real failure: keep the cache-hydrated grid, surface error only when there's nothing to show.
            loadFailed = items.isEmpty
            isLoading = false
            return
        }
        loadFailed = false
        let phase1 = browsable(phase1Response.items)
        studioItems = phase1
        totalRecordCount = phase1Response.totalRecordCount

        var tmdbMap: [Int: JellyfinItem] = [:]
        for item in allItems ?? [] {
            if let id = item.tmdbID { tmdbMap[id] = item }
        }

        // No cache yet: surface the studio match while the watch-provider phase runs.
        if items.isEmpty {
            items = phase1
            isLoading = false
        }

        // Always refresh (stale-while-revalidate): the fresh list replaces the cache so titles rotated off the service drop out.
        if let providerID = smartProviderID, let region = smartProviderRegion {
            // tmdbMap's 10k scan failed: the augment would resolve against an empty map and shrink to studio-only. Skip the refresh.
            guard allItems != nil else {
                isLoading = false
                return
            }
            await refreshWatchProviderAugment(
                providerID: providerID,
                region: region,
                tmdbMap: tmdbMap,
                generation: generation,
                isWatchFiltered: isWatchFiltered
            )
        } else {
            // No smart filter (broadcast nets, genre/studio tiles): phase 1 is final. Skip the assignment on an unchanged id list (a wholesale replace re-diffs every cell, a reload flash), and keep appended pages when the user paginated (didPaginate; the old prefix heuristic broke on a page-1 server reorder).
            let pagedPastPhase1 = didPaginate && !items.isEmpty
            if !pagedPastPhase1, items.map(\.id) != phase1.map(\.id) {
                items = phase1
            }
            isLoading = false
            // Cache only the unfiltered default order: it feeds init hydration (always .all, always
            // Title A-Z) + empty-tile-hide counts, both needing the full library in the shipped order.
            if let scope = cacheScope, !isWatchFiltered, sort == .default {
                FilterCache.shared.setHomeFilterItems(
                    phase1, filterKey: scope.key, identity: scope.identity
                )
            }
        }
    }

    // MARK: - Pagination

    /// More pages exist server-side. Only the plain path paginates: smart-provider grids are merged from the full library map and complete by construction.
    private var canLoadMore: Bool {
        guard smartProviderID == nil, query.limit != nil else { return false }
        guard !reachedEnd, let total = totalRecordCount else { return false }
        return items.count < total
    }

    private func loadMoreIfNeeded(after item: JellyfinItem) {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        // Trigger within the last two rows so the next page lands before focus reaches the edge.
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 12 else { return }
        isLoadingMore = true
        Task { await loadMore() }
    }

    private func loadMore() async {
        defer { isLoadingMore = false }
        guard let userID = appState.activeUser?.id else { return }
        let generation = loadGeneration

        var pageQuery = sort.applied(to: query)
        if let filter = watchFilter.jellyfinFilter {
            pageQuery.filters = [filter]
        }
        // Seed the cursor from the already-loaded first page, then advance it by the raw fetched count
        // below so an all-duplicate page can't pin it.
        if nextStartIndex == 0 { nextStartIndex = items.count }
        pageQuery.startIndex = nextStartIndex

        guard let response = try? await dependencies.jellyfinLibraryService.getItems(
            userID: userID, query: pageQuery
        ) else { return }
        guard !Task.isCancelled, generation == loadGeneration else { return }

        totalRecordCount = response.totalRecordCount
        nextStartIndex += response.items.count
        let known = Set(items.map(\.id))
        items += browsable(response.items).filter { !known.contains($0.id) }
        didPaginate = true
        // A short/empty page means the server has no more rows; stop even if dedup left items.count
        // below totalRecordCount, so canLoadMore can't loop on the same overlapping window.
        if let limit = query.limit, response.items.count < limit {
            reachedEnd = true
        }
    }

    /// Refresh the TMDB watch-provider id list, re-resolve against the local map, cache the fresh ids. Stale entries drop out because the merged grid is rebuilt from scratch.
    private func refreshWatchProviderAugment(
        providerID: Int,
        region: String,
        tmdbMap: [Int: JellyfinItem],
        generation: Int,
        isWatchFiltered: Bool
    ) async {
        let providerTmdbIDs = await dependencies.seerrDiscoverService
            .collectWatchProviderTmdbIDs(providerID: providerID, region: region)

        guard !Task.isCancelled, generation == loadGeneration else { return }

        // collectWatchProviderTmdbIDs swallows failures into an empty set, ambiguous with "service streams nothing". A real service never has zero, so treat empty as a failed round: keep the grid + cache, surface phase 1 only if nothing's showing.
        guard !providerTmdbIDs.isEmpty else {
            if items.isEmpty {
                items = studioItems
            }
            isLoading = false
            return
        }

        let phase2Items = providerTmdbIDs.compactMap { tmdbMap[$0] }
        let merged = ProviderMatchMerging.merge(phase1: studioItems, phase2: phase2Items)
        if items.map(\.id) != merged.map(\.id) {
            items = merged
        }
        isLoading = false

        // Persist the resolved list so the next visit hydrates synchronously, no library fetch or watch-provider roundtrip. Unfiltered default only (phase-1 rationale).
        if let scope = cacheScope, !isWatchFiltered, sort == .default {
            FilterCache.shared.setHomeFilterItems(
                merged, filterKey: scope.key, identity: scope.identity
            )
        }
    }
}

struct GridCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Stroke drawn inside MediaCard (poster only), keeping the title below outside the outline.
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

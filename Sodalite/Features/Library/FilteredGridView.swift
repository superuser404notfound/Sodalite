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
    @Environment(\.serverSession) private var serverSessionOverride
    /// The item's own server in a combined Home, the active one otherwise (Sodalite#85).
    private var session: ServerSession { serverSessionOverride ?? dependencies.sessionRegistry.active }
    private var sessionUserID: String? { session.isActive ? appState.activeUser?.id : session.userID }
    @State private var items: [JellyfinItem]
    @State private var isLoading: Bool
    @State private var selectedItem: JellyfinItem?
    /// A folder tapped in a folder-browsed library; opens its own grid one level down (Sodalite#180).
    @State private var selectedFolder: JellyfinItem?
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
    /// The plain grid's slots (Sodalite#86); merged and smart-provider grids keep `items`.
    @State private var store: SparseGridStore
    @FocusState private var focusedSlot: Int?
    /// The reload key the store was started under; a reappear with the same key revalidates instead.
    @State private var storeKey: ReloadKey?
    /// Alphabet rail (Sodalite#86): letter to slot, against the same query the grid pages.
    @State private var resolver: AlphabetJumpResolver?
    @State private var railBaseQuery: ItemQuery?
    @State private var jumpTask: Task<Void, Never>?
    @State private var gridLetter: String?
    @State private var rejectedLetter: (letter: String, attempt: Int)?
    /// A committed jump's slot. Leaving the rail to the left also moves focus geometrically, and
    /// that move lands after ours, so the grid redirects the first arrival here once.
    @State private var pendingFocusSlot: Int?
    @Environment(\.dismiss) private var dismiss

    /// Distinguishes "fetch failed, nothing to show" (retry state) from "server says empty".
    @State private var loadFailed = false
    /// Stamped per loadItems run, checked after each await so a superseded run (filter flip, retry) can't write over the newer one.
    @State private var loadGeneration = 0
    @State private var isLoadingMore = false
    /// True once loadMore appended a page this cycle; the refresh keeps appended pages instead of truncating to page 1. Explicit flag, not a prefix heuristic: a page-1 server reorder breaks prefix comparison.
    @State private var didPaginate = false

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
    /// A combined Home's servers, active first; with more than one the grid pages through all of
    /// them (Sodalite#85). nil or one entry keeps the single-server path.
    let sources: [HomeSource]?
    @State private var mergedGrid = MergedGridState()
    /// A combined provider grid whose secondary dropped out this round: shown, never cached.
    @State private var combinedIncomplete = false
    private var isMerged: Bool { (sources?.count ?? 0) > 1 }
    /// Every grid that pages one server's list: fixed slots, a page fetched where it is looked at.
    private var usesSparseGrid: Bool { Self.usesSparseGrid(sources: sources, smartProviderID: smartProviderID, query: query) }
    private static func usesSparseGrid(sources: [HomeSource]?, smartProviderID: Int?, query: ItemQuery) -> Bool {
        (sources?.count ?? 0) <= 1 && smartProviderID == nil && query.limit != nil
    }
    /// One level of a folder tree (Sodalite#180): only `MyMediaLibraries.folderQuery` asks non-recursively.
    private var browsesFolders: Bool { !query.recursive }
    /// Home videos are 16:9 stills, so a folder grid lays out wide cards.
    private var cardStyle: MediaCardStyle { browsesFolders ? .landscape : .poster }

    init(
        title: String,
        query: ItemQuery,
        smartProviderID: Int? = nil,
        smartProviderRegion: String? = nil,
        cacheScope: FilterCacheScope? = nil,
        sortScope: LibrarySortScope? = nil,
        hidesAudioPlaylists: Bool = false,
        sources: [HomeSource]? = nil
    ) {
        self.title = title
        self.query = query
        self.smartProviderID = smartProviderID
        self.smartProviderRegion = smartProviderRegion
        self.cacheScope = cacheScope
        self.sortScope = sortScope
        self.hidesAudioPlaylists = hidesAudioPlaylists
        self.sources = sources
        let storedSort = sortScope.map(LibrarySortStore.sort) ?? .default
        _sort = State(initialValue: storedSort)
        // Hydrate from FilterCache in init so the first render paints the cached grid; doing it in .task means a frame with isLoading=true first (the brief loading flash on every tap).
        // Only the default sort: the cache holds one order per key, so a custom sort would paint the
        // alphabetical list and then reshuffle it once the fetch lands.
        let sparse = Self.usesSparseGrid(sources: sources, smartProviderID: smartProviderID, query: query)
        if storedSort == .default,
           let scope = cacheScope,
           let cached = FilterCache.shared.homeFilterItems(filterKey: scope.key, identity: scope.identity),
           !cached.isEmpty {
            _items = State(initialValue: sparse ? [] : cached)
            _store = State(initialValue: SparseGridStore(pageSize: query.limit ?? 50, seed: sparse ? cached : []))
            _isLoading = State(initialValue: false)
        } else {
            _items = State(initialValue: [])
            _store = State(initialValue: SparseGridStore(pageSize: query.limit ?? 50))
            _isLoading = State(initialValue: true)
        }
    }

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        ScrollViewReader { proxy in
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
                            guard let userID = sessionUserID else { return }
                            // Shows libraries shuffle episodes across the whole
                            // library; everything else keeps its own item types.
                            var types = query.includeItemTypes ?? [.movie]
                            if types.contains(.series) { types = [.episode] }
                            if browsesFolders { types = [.video] }
                            Task {
                                let queue = await VideoShuffleQueue.build(
                                    parentID: query.parentID,
                                    baseQuery: query,
                                    itemTypes: types,
                                    service: session.libraryService,
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
                        onRetry: { await retry() },
                        onOpenDownloads: dependencies.downloadStore.items.isEmpty ? nil : { appState.requestedTab = .downloads }
                    )
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else if gridIsEmpty {
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
                        GridItem(
                            .adaptive(minimum: metrics.gridColumnMinimum(
                                for: cardStyle,
                                cardScale: dependencies.appearancePreferences.cardScale)),
                            spacing: metrics.gridSpacing
                        )
                    ], spacing: metrics.gridSpacing) {
                        if usesSparseGrid {
                            ForEach(store.visibleIndices, id: \.self) { index in
                                sparseCell(index)
                                    .id(index)
                                    .onAppear { store.slotAppeared(index) }
                                    .onDisappear { store.slotDisappeared(index) }
                            }
                        } else {
                        ForEach(items, id: \.originKey) { item in
                            Button {
                                open(item)
                            } label: {
                                MediaCard(
                                    item: item,
                                    imageURL: browsesFolders
                                        ? dependencies.jellyfinImageService.folderBrowseArtworkURL(for: item)
                                        : dependencies.jellyfinImageService.posterURL(for: item),
                                    style: cardStyle,
                                    isFocused: focusedItemID == item.originKey
                                )
                            }
                            .buttonStyle(GridCardButtonStyle())
                            .focused($focusedItemID, equals: item.originKey)
                            .onAppear { loadMoreIfNeeded(after: item) }
                        }
                        }
                    }
                    .padding(.horizontal, metrics.gridInset)
                    .padding(.trailing, showsRail ? Self.railClearance : 0)
                    .padding(.vertical, 40)
                    #if os(iOS)
                    .scrollTargetLayout()
                    .onScrollTargetVisibilityChange(idType: Int.self) { ids in
                        guard let top = ids.min(), let item = store.item(at: top) else { return }
                        gridLetter = AlphabetIndex.letter(for: item.sortName ?? item.name)
                    }
                    #endif
                    .enrichesPosterBadges(usesSparseGrid ? store.loadedItems : items)

                    if isLoadingMore {
                        ProgressView()
                            .padding(.bottom, 40)
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if showsRail { rail(proxy) }
            }
        }
        .overlay {
            if let userID = sessionUserID {
                PlayerLauncher(
                    isPresented: $showPlayer,
                    item: showPlayer ? playItem : nil,
                    startFromBeginning: true,
                    playbackService: session.playbackService,
                    itemService: session.itemService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    trackMemory: dependencies.trackSelectionMemory,
                    spoilerPolicy: dependencies.spoilerPolicy(userID: appState.activeUser?.id),
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
        .navigationDestination(item: $selectedFolder) { folder in
            // The library's sort scope carries down, so one choice orders the whole tree.
            FilteredGridView(
                title: folder.name,
                query: MyMediaLibraries.folderQuery(parentID: folder.id),
                cacheScope: cacheScope.map {
                    FilterCacheScope(key: FilterCacheKey.Home.folder(id: folder.id), identity: $0.identity)
                },
                sortScope: sortScope
            )
        }
        .menuPresentation(isPresented: $showSortSheet) {
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
            didPaginate = false
            mergedGrid.reset()
            store.reset()
            storeKey = nil
            jumpTask?.cancel()
            gridLetter = nil
            rejectedLetter = nil
        }
        .onChange(of: focusedSlot) { _, slot in
            if let target = pendingFocusSlot, let slot {
                if slot == target {
                    pendingFocusSlot = nil
                } else {
                    // Set inside the engine's own transition the assignment is dropped; one turn
                    // of the main actor later it sticks.
                    Task { focusedSlot = target }
                    return
                }
            }
            guard let slot, let item = store.item(at: slot) else { return }
            gridLetter = AlphabetIndex.letter(for: item.sortName ?? item.name)
        }
        .onChange(of: store.firstPage) { _, state in
            guard usesSparseGrid else { return }
            switch state {
            case .loading:
                break
            case .failed:
                loadFailed = store.slots.isEmpty
                isLoading = false
            case .loaded(let page):
                loadFailed = false
                isLoading = false
                // Same rule as before: only the unfiltered default order feeds init hydration.
                if let scope = cacheScope, watchFilter == .all, sort == .default {
                    FilterCache.shared.setHomeFilterItems(
                        browsable(page), filterKey: scope.key, identity: scope.identity
                    )
                }
            }
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
            hasContent: usesSparseGrid ? !store.slots.isEmpty : !items.isEmpty,
            loadFailedEntirely: loadFailed
        )
    }

    private var showsRail: Bool {
        AlphabetIndex.showsRail(sortKey: sort.key, usesSparseGrid: usesSparseGrid, total: store.slots.count)
    }

    #if os(tvOS)
    private static let railClearance: CGFloat = 48
    #else
    private static let railClearance: CGFloat = 24
    #endif

    private func rail(_ proxy: ScrollViewProxy) -> some View {
        AlphabetRail(
            letters: AlphabetIndex.railLetters(descending: sort.descending),
            highlighted: gridLetter,
            rejected: rejectedLetter,
            onLetter: { jump(to: $0, proxy: proxy, commit: false) },
            onCommit: { jump(to: $0, proxy: proxy, commit: true) }
        )
        .padding(.trailing, metrics.gridInset / 2)
    }

    /// A settled letter scrolls the grid to its first slot; a commit also moves focus there. The
    /// slot's page is pushed to the front, so only the destination is fetched.
    private func jump(to letter: String, proxy: ScrollViewProxy, commit: Bool) {
        jumpTask?.cancel()
        jumpTask = Task {
            if !commit {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard let resolver, let base = railBaseQuery else { return }
            guard let raw = await resolver.slot(for: letter, base: base, descending: sort.descending) else {
                if !Task.isCancelled {
                    rejectedLetter = (letter, (rejectedLetter?.attempt ?? 0) + 1)
                }
                return
            }
            guard !Task.isCancelled, let slot = store.visibleIndex(atOrAfter: raw) else { return }
            store.prioritize(slot: slot)
            gridLetter = letter
            proxy.scrollTo(slot, anchor: .topLeading)
            if commit {
                pendingFocusSlot = slot
                focusedSlot = slot
            }
        }
    }

    private var gridIsEmpty: Bool {
        usesSparseGrid ? store.visibleIndices.isEmpty : items.isEmpty
    }

    private func open(_ item: JellyfinItem) {
        if item.type == .folder { selectedFolder = item } else { selectedItem = item }
    }

    /// A slot's card, or its placeholder until the page lands. Both focusable under the slot index,
    /// so focus survives the swap and a jump can land before the page has.
    @ViewBuilder
    private func sparseCell(_ index: Int) -> some View {
        if let item = store.item(at: index) {
            Button { open(item) } label: {
                MediaCard(
                    item: item,
                    imageURL: browsesFolders
                        ? dependencies.jellyfinImageService.folderBrowseArtworkURL(for: item)
                        : dependencies.jellyfinImageService.posterURL(for: item),
                    style: cardStyle,
                    isFocused: focusedSlot == index
                )
            }
            .buttonStyle(GridCardButtonStyle())
            .focused($focusedSlot, equals: index)
        } else {
            Button {} label: { PlaceholderCard(style: cardStyle, isFocused: focusedSlot == index) }
                .buttonStyle(GridCardButtonStyle())
                .focused($focusedSlot, equals: index)
        }
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

    /// The resolved TMDB watch-provider augment (phase 2), reused on a reappear instead of
    /// re-running the 10 000-item scan (Sodalite#68, the biggest request the app makes) and the
    /// ~10 Seerr calls that built it (Audit 2026-09-25 BROWSE-6). A NavigationStack push/pop through
    /// this grid's own navigationDestination re-fires `.task(id: reloadKey)` with an unchanged key
    /// (the same quirk HomeView.swift:24 documents against), and the augment does not change between
    /// two detail visits, or across a sort change: only the watch filter narrows it.
    @State private var cachedPhase2Items: [JellyfinItem] = []
    /// The watch filter `cachedPhase2Items` was resolved under; nil until the first resolve lands.
    @State private var phase2CacheFilter: WatchStatusFilter?

    /// Anything that invalidates the loaded page set: both a filter flip and a sort change need the
    /// same reset (grid, pagination cursor, end marker) before the keyed task refetches.
    private struct ReloadKey: Equatable {
        let filter: WatchStatusFilter
        let sort: LibrarySort
    }

    private var reloadKey: ReloadKey { ReloadKey(filter: watchFilter, sort: sort) }

    /// Narrowing the server cannot express. On the sparse grid the same rule hides a slot instead
    /// (`SparseGridStore` keeps the server's count).
    private func browsable(_ items: [JellyfinItem]) -> [JellyfinItem] {
        hidesAudioPlaylists ? items.filter { !$0.isAudioPlaylist } : items
    }

    /// Whether a load can skip the 10 000-item scan and the Seerr watch-provider calls and reuse
    /// what the last full load resolved into `cachedPhase2Items` (Audit 2026-09-25 BROWSE-6): only
    /// for a smart-provider tile (the two-phase augment only exists there), and only when the cached
    /// resolve belongs to the SAME watch filter, since the filter narrows both phases server-side.
    static func canReuseCachedPhase2(
        smartProviderID: Int?, cacheFilter: WatchStatusFilter?, currentFilter: WatchStatusFilter
    ) -> Bool {
        smartProviderID != nil && cacheFilter == currentFilter
    }

    private func loadItems() async {
        guard let userID = sessionUserID else { return }
        loadGeneration += 1
        let generation = loadGeneration

        // Watch-status filter applies server-side to BOTH phases (phase 1 + the full-library map phase 2 resolves against), so phase 2 can't re-introduce filtered-out items.
        var effectiveQuery = sort.applied(to: query)
        if let filter = watchFilter.jellyfinFilter {
            effectiveQuery.filters = [filter]
        }
        let isWatchFiltered = watchFilter != .all

        // A reappear with an already-resolved augment for this filter: skip the scan below and the
        // Seerr calls behind refreshWatchProviderAugment entirely (BROWSE-6).
        let reusePhase2 = Self.canReuseCachedPhase2(
            smartProviderID: smartProviderID, cacheFilter: phase2CacheFilter, currentFilter: watchFilter
        )

        if usesSparseGrid {
            if storeKey == reloadKey, !store.slots.isEmpty, store.firstPage != .failed {
                store.revalidate()
                return
            }
            let service = session.libraryService
            let seed = storeKey == nil ? store.loadedItems : []
            storeKey = reloadKey
            railBaseQuery = effectiveQuery
            resolver = AlphabetJumpResolver(count: { query in
                try await service.getItems(userID: userID, query: query).totalRecordCount
            })
            store.start(
                fetch: { [effectiveQuery] start, limit in
                    var page = effectiveQuery
                    page.startIndex = start
                    page.limit = limit
                    return try await service.getItems(userID: userID, query: page)
                },
                isHidden: { [hidesAudioPlaylists] in hidesAudioPlaylists && $0.isAudioPlaylist },
                seed: seed
            )
            return
        }

        // A combined Home's genre or studio grid: every server, one sort order (Sodalite#85).
        if isMerged, smartProviderID == nil, let sources {
            let outcome = await mergedGrid.load(
                sources: MergedPager.sources(from: sources, query: effectiveQuery),
                sort: sort, pageSize: query.limit ?? 50, filter: browsable)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            switch outcome {
            case .kept:
                break
            case .failed:
                loadFailed = items.isEmpty
            case .replaced(let cacheable):
                loadFailed = false
                if items.map(\.originKey) != mergedGrid.items.map(\.originKey) { items = mergedGrid.items }
                if cacheable, let scope = cacheScope, !isWatchFiltered, sort == .default {
                    FilterCache.shared.setHomeFilterItems(mergedGrid.items, filterKey: scope.key, identity: scope.identity)
                }
            }
            isLoading = false
            return
        }

        let phase1Response: JellyfinItemsResponse?
        let allItems: [JellyfinItem]?
        var combinedTmdbMap: [String: JellyfinItem]?
        if isMerged, let sources, smartProviderID != nil {
            // A combined Home's provider tile: both phases from every server (Sodalite#85).
            var libraryQuery = ItemQuery(
                includeItemTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 10000,
                fields: JellyfinEndpoint.homeRowFields + ",ProviderIds"
            )
            if let filter = watchFilter.jellyfinFilter { libraryQuery.filters = [filter] }
            let combined = await CombinedProviderMatch.fetch(
                sources: sources, studioQuery: effectiveQuery,
                libraryQuery: reusePhase2 ? nil : libraryQuery,
                studioDeadline: .seconds(4), scanDeadline: .seconds(20))
            phase1Response = combined.phase1
            allItems = combined.allItems
            combinedTmdbMap = combined.tmdbMap
            combinedIncomplete = !combined.complete
        } else {
            // nil = fetch failed/cancelled, distinct from "server empty": a failure must never replace the grid or persist into FilterCache as a valid empty (that poisoned the cache and killed instant-paint until the next pre-warm).
            async let studioMatchTask: JellyfinItemsResponse? = { [effectiveQuery] in
                try? await session.libraryService.getItems(
                    userID: userID, query: effectiveQuery
                )
            }()

            async let allLibraryTask: [JellyfinItem]? = { [watchFilterValue = watchFilter.jellyfinFilter] in
                guard smartProviderID != nil, !reusePhase2 else { return [] }
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
                return try? await session.libraryService.getItems(
                    userID: userID, query: allQuery
                ).items
            }()
            phase1Response = await studioMatchTask
            allItems = await allLibraryTask
        }

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

        var tmdbMap: [String: JellyfinItem] = combinedTmdbMap ?? [:]
        if combinedTmdbMap == nil {
            for item in allItems ?? [] {
                if let id = item.tmdbID {
                    tmdbMap[ProviderMatchMerging.tmdbKey(type: item.type, tmdbID: id)] = item
                }
            }
        }

        // No cache yet: surface the studio match while the watch-provider phase runs.
        if items.isEmpty {
            items = phase1
            isLoading = false
        }

        // Always refresh (stale-while-revalidate): the fresh list replaces the cache so titles rotated off the service drop out. Except on a reappear (BROWSE-6): the studio query above still ran fresh (a watched toggle under Unwatched, say), but the augment reuses what the last full load resolved.
        if let providerID = smartProviderID, let region = smartProviderRegion {
            if reusePhase2 {
                let merged = isMerged
                    ? CombinedProviderMatch.mergePhases(phase1: phase1, phase2: cachedPhase2Items)
                    : ProviderMatchMerging.merge(phase1: phase1, phase2: cachedPhase2Items)
                if items.map(\.originKey) != merged.map(\.originKey) { items = merged }
                isLoading = false
                return
            }
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
            if !pagedPastPhase1, items.map(\.originKey) != phase1.map(\.originKey) {
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

    /// More pages exist server-side. Only the merged grid paginates here: smart-provider grids are complete by construction, single-server grids fill slots.
    private var canLoadMore: Bool {
        isMerged && smartProviderID == nil && mergedGrid.hasMore
    }

    private func loadMoreIfNeeded(after item: JellyfinItem) {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        // Trigger within the last two rows so the next page lands before focus reaches the edge.
        guard let index = items.firstIndex(where: { $0.originKey == item.originKey }),
              index >= items.count - 12 else { return }
        isLoadingMore = true
        Task { await loadMore() }
    }

    /// Only the merged grid still pages by cursor; the single-server grid fills slots (Sodalite#86).
    private func loadMore() async {
        defer { isLoadingMore = false }
        guard isMerged, smartProviderID == nil else { return }
        let generation = loadGeneration
        guard await mergedGrid.loadMore(filter: browsable),
              !Task.isCancelled, generation == loadGeneration else { return }
        items = mergedGrid.items
        didPaginate = true
    }

    /// Refresh the TMDB watch-provider id list, re-resolve against the local map, cache the fresh ids. Stale entries drop out because the merged grid is rebuilt from scratch.
    private func refreshWatchProviderAugment(
        providerID: Int,
        region: String,
        tmdbMap: [String: JellyfinItem],
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
        cachedPhase2Items = phase2Items
        phase2CacheFilter = watchFilter
        let merged = isMerged
            ? CombinedProviderMatch.mergePhases(phase1: studioItems, phase2: phase2Items)
            : ProviderMatchMerging.merge(phase1: studioItems, phase2: phase2Items)
        // A secondary dropped out this round: what the precompute cached from all servers stays.
        if combinedIncomplete, !items.isEmpty {
            isLoading = false
            return
        }
        if items.map(\.originKey) != merged.map(\.originKey) {
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
            .focusResponse(.card, isFocused: isFocused)
    }
}

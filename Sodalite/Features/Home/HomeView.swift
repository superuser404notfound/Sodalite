import SwiftUI

struct HomeView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @State private var viewModel: HomeViewModel?
    @State private var selectedItem: JellyfinItem?
    @State private var selectedFilter: FilterDestination?

    /// Spinner accent: HomeView's NavigationStack resets the inherited TabView tint to white, so re-apply the effective tint to match the Live TV spinner.
    private var spinnerTint: Color {
        dependencies.appearancePreferences.effectiveTint(
            isSupporter: dependencies.storeKitService.isSupporter
        )
    }

    /// Which content row holds focus; nil when focus leaves the rows (Up from the top row to the tab bar). Drives auto-scroll-to-top so the tab bar isn't clipped on arrival from below.
    @FocusState private var focusedRowIndex: Int?

    /// Debounce for the focus-left-rows → scroll-to-top, cancelled/respawned on focus change; without it transient nils between row transitions trigger spurious scroll-to-top snaps.
    @State private var scrollResetTask: Task<Void, Never>?

    /// Last serverDidSwitch this view reacted to. .task(id:) re-fires with the same id on every reappear; without the latch each reappear would wipe FilterCache and reload the whole feed.
    @State private var lastHandledServerSwitch = 0

    /// Same latch for requestContentReload, and for the same reason: without it every reappear would
    /// reload the whole feed on a signal that was already answered.
    @State private var lastHandledContentReload = 0

    /// Presents the single-field sheet that fills the server's empty URL slot (iOS only; tvOS has
    /// no URL editor).
    @State private var showAddURLSheet = false

    private static let refreshStaleSeconds: TimeInterval = 60

    var body: some View {
        ThemeNavigationStack {
            Group {
                if let vm = viewModel {
                    if let state = blockingState(vm: vm) {
                        ServerUnreachableView(
                            state: state,
                            serverName: appState.activeServer?.name ?? "",
                            onAddExternalAddress: addExternalAddressAction(for: state),
                            onRetry: { await retry(vm: vm) }
                        )
                    } else if vm.isLoading {
                        ProgressView()
                            .tint(spinnerTint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        contentView(vm: vm)
                    }
                } else {
                    ProgressView()
                        .tint(spinnerTint)
                }
            }
            // Full-screen cover (over the tab bar) instead of a push: the bar is never hidden/removed, so it is never re-templated gray on return (tvOS 26). See detailCover.
            .detailCover(item: $selectedItem) { item in
                DetailRouterView(item: item)
            }
            .detailCover(item: $selectedFilter) { filter in
                FilteredGridView(
                    title: filter.title,
                    query: filter.query,
                    smartProviderID: filter.smartProviderID,
                    smartProviderRegion: filter.smartProviderRegion,
                    cacheScope: filter.cacheScope,
                    sortScope: filter.sortScope,
                    hidesAudioPlaylists: filter.hidesAudioPlaylists
                )
            }
        }
        .onAppear {
            guard let userID = appState.activeUser?.id else { return }
            if viewModel == nil {
                viewModel = HomeViewModel(
                    libraryService: dependencies.jellyfinLibraryService,
                    imageService: dependencies.jellyfinImageService,
                    discoverService: dependencies.seerrDiscoverService,
                    userID: userID,
                    serverID: appState.activeServer?.id ?? userID
                )
                Task { await viewModel?.loadContent() }
            } else if let last = viewModel?.lastLoadedAt,
                      Date().timeIntervalSince(last) > Self.refreshStaleSeconds {
                // Pick up new server-side content on return after 60 s: tight enough to show additions fast, loose enough that tab-hopping doesn't spam the server.
                Task { await viewModel?.loadContent() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeConfigDidChange)) { _ in
            viewModel?.reloadConfig()
            viewModel?.scheduleConfigReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeFavoritesDidChange)) { _ in
            Task { await viewModel?.loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homePlayedDidChange)) { _ in
            Task { await viewModel?.loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { note in
            // Patch the tile progress in place from the payload (race-free), then reload for structural changes (reorder, finished drop-out), then re-apply so a stale cached re-fetch can't regress the bar (issue #24).
            let itemID = note.userInfo?[PlaybackProgressKey.itemID] as? String
            let ticks = note.userInfo?[PlaybackProgressKey.positionTicks] as? Int64
            Task { @MainActor in
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                await viewModel?.loadContent()
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryItemDidReplace)) { _ in
            // Continue Watching is holding the id the library just replaced; reload so the row points at
            // the new item instead of failing playback on the corpse.
            Task { await viewModel?.loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeItemDidDelete)) { _ in
            // Reload so the deleted item drops out immediately instead of lingering until the next stale refresh.
            Task { await viewModel?.loadContent() }
        }
        .onChange(of: appState.activeUser?.id) { _, newValue in
            // Profile switch: tear down the old VM so .onAppear rebuilds it with the new userID (else it keeps loading the previous profile's permissions/watch state).
            guard let userID = newValue else {
                viewModel = nil
                return
            }
            viewModel = HomeViewModel(
                libraryService: dependencies.jellyfinLibraryService,
                imageService: dependencies.jellyfinImageService,
                discoverService: dependencies.seerrDiscoverService,
                userID: userID,
                serverID: appState.activeServer?.id ?? userID
            )
            Task { await viewModel?.loadContent() }
        }
        .task(id: appState.serverDidSwitch) {
            // Value 0 is the initial state; no switch has occurred yet.
            let signal = appState.serverDidSwitch
            guard signal > 0, signal != lastHandledServerSwitch else { return }
            lastHandledServerSwitch = signal
            // Roll the latch back if cancelled mid-reload so the reappear re-fire finishes the job instead of being guarded away.
            defer {
                if Task.isCancelled, lastHandledServerSwitch == signal {
                    lastHandledServerSwitch = 0
                }
            }
            // FilterCache needs no handling here: its entries are scoped per identity, so the
            // rows this reload fetches and the tile grids on disk cannot cross sessions.
            await viewModel?.reloadAfterServerSwitch()
        }
        // A cause outside Home has made its last failure obsolete (the Local Network permission came
        // back, Sodalite#92). Home is still showing the error it hit while that was off, and only a
        // reload can retire it.
        .task(id: appState.requestContentReload) {
            let signal = appState.requestContentReload
            guard signal > 0, signal != lastHandledContentReload else { return }
            lastHandledContentReload = signal
            defer {
                if Task.isCancelled, lastHandledContentReload == signal {
                    lastHandledContentReload = 0
                }
            }
            await viewModel?.loadContent()
        }
        // Pre-warm row artwork as rows land so first focus doesn't pay round-trip + decode. Keyed on the cross-row item-id set so it re-fires whenever row membership changes.
        .onChange(of: viewModel?.rows.flatMap({ $0.items.map(\.id) })) { _, _ in
            if let vm = viewModel { prefetchHomePosters(vm) }
        }
        #if os(iOS)
        // The fix for an off-network server, offered where the failure is (Sodalite#122). Same
        // single-field sheet the post-login prompt uses, so the address is validated and saved by
        // exactly one path.
        .sheet(isPresented: $showAddURLSheet) {
            if let server = appState.activeServer, let slot = server.emptyURLSlot {
                AddSecondURLSheet(
                    slot: slot,
                    knownURL: server.url,
                    resolve: ServerAddressResolution.jellyfin(dependencies.serverDiscoveryService),
                    onSave: { newURL in
                        let merged = server.urls(filling: slot, with: newURL)
                        try? dependencies.updateServerURLs(
                            serverID: server.id,
                            internalURL: merged.internal,
                            externalURL: merged.external
                        )
                        // Re-probe at once: the new slot is the whole point, and the verdict it
                        // clears is what put this screen on the display.
                        dependencies.scheduleRouteResolve()
                    }
                )
            }
        }
        #endif
    }

    /// What Home shows instead of content, or nil to keep loading or keep showing rows.
    ///
    /// Two sources, and the fast one is the point of Sodalite#122. The route probe settles the
    /// question about two seconds into launch; the row fan-out needs thirty seconds to three minutes
    /// to prove the same thing one request timeout at a time, which nobody waits for. So the probe's
    /// verdict speaks as soon as it lands, and Home stops sitting on a bare spinner behind it.
    ///
    /// Only while nothing has painted. A row that arrives anyway clears the screen: the probe asked
    /// one endpoint, and a server that is demonstrably answering outranks it. That is also what
    /// keeps a dual-slot server whose external route is carrying the session from ever seeing this,
    /// and what keeps the still-loading first seconds from flashing it.
    private func blockingState(vm: HomeViewModel) -> ServerReachability? {
        // A feed painted from disk is not evidence that the server answered (Sodalite#117), so the
        // verdict still speaks over it. Otherwise a cached shelf would stand in front of the
        // sentence that explains why none of its posters can load.
        guard vm.rows.isEmpty || vm.isShowingCachedFeed, vm.tagRows.isEmpty else { return nil }
        switch appState.serverReachability {
        case .noNetwork, .offNetwork, .unreachable:
            return appState.serverReachability
        case .reachable, .unknown:
            // No verdict against the server, or none yet: only the fan-out draining empty may speak,
            // and it cannot say why.
            return vm.loadFailedEntirely ? .unreachable : nil
        }
    }

    /// The add-an-external-address action, where there is both a slot to fill and a sheet to fill
    /// it in.
    ///
    /// tvOS has no URL editor at all, so there it stays nil and the screen offers Retry alone: a
    /// button that leads nowhere is worse than no button. The sentence above it is true on both.
    private func addExternalAddressAction(for state: ServerReachability) -> (() -> Void)? {
        #if os(iOS)
        guard state == .offNetwork, appState.activeServer?.emptyURLSlot != nil else { return nil }
        return { showAddURLSheet = true }
        #else
        return nil
        #endif
    }

    /// Retry re-probes before it re-fetches, else the reload would run against the same stale
    /// verdict and paint this screen straight back.
    ///
    /// Only the probe is awaited. It settles in seconds and it is what decides whether this screen
    /// stays; the fan-out behind it needs the full round of request timeouts to give up on a server
    /// that is still down, and a Retry button that spins for three minutes would be the very bug
    /// this screen exists to remove.
    private func retry(vm: HomeViewModel) async {
        await dependencies.resolveActiveRoutes()
        Task { await vm.loadContent() }
    }

    /// Sodalite#66. True for an item the veil would blur while the row is showing show-level art
    /// (Continue Watching on Backdrop or Thumb). Its chain then stays off the episode's own still,
    /// and the card shows the show art unblurred: a backdrop is marketing art, not a plot point.
    private func needsSpoilerSafeArtwork(
        _ item: JellyfinItem,
        cwImage: AppearancePreferences.ContinueWatchingImage
    ) -> Bool {
        guard cwImage != .still else { return false }
        return SpoilerReveal.isHidden(
            item, dependencies: dependencies, appState: appState, surface: .artwork
        )
    }

    /// Hand the loaded rows' artwork URLs to `ImageCache.prefetch` so first focus doesn't pay round-trip + decode. Mirrors `SearchView.prefetchSearchPosters`: cached URLs are skipped and the fan-out is bounded, so it never starves foreground fetches. Reuses `vm.imageURL` so prefetched URLs match exactly what the cards request.
    private func prefetchHomePosters(_ vm: HomeViewModel) {
        var urls: [URL] = []
        for row in vm.rows {
            let cwImage = row.type.usesBackdrop
                ? dependencies.appearancePreferences.continueWatchingImage
                : .still
            for item in row.items {
                let spoilerSafe = needsSpoilerSafeArtwork(item, cwImage: cwImage)
                if let url = vm.imageURL(
                    for: item, rowType: row.type, cwImage: cwImage, spoilerSafe: spoilerSafe
                ) {
                    urls.append(url)
                }
            }
        }
        guard !urls.isEmpty else { return }
        let token = dependencies.jellyfinClient.accessToken
        let host = dependencies.jellyfinClient.baseURL?.host
        Task.detached(priority: .utility) {
            await ImageCache.prefetch(urls, authToken: token, jellyfinHost: host)
        }
    }

    private func contentView(vm: HomeViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Invisible zero-height scroll-to-top anchor for when focus leaves the rows.
                Color.clear.frame(height: 0).id("top")
                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(Array(vm.orderedSections().enumerated()), id: \.element.id) { idx, section in
                    switch section {
                    case .media(let row):
                        let cwImage = row.type.usesBackdrop
                            ? dependencies.appearancePreferences.continueWatchingImage
                            : .still
                        HorizontalMediaRow(
                            title: row.type.localizedTitle,
                            verbatimTitle: row.type == .libraryLatest
                                ? String(
                                    format: String(
                                        localized: "home.libraryLatest.format",
                                        defaultValue: "Latest in %@"
                                    ),
                                    row.libraryName ?? ""
                                )
                                : nil,
                            items: row.items,
                            imageURLProvider: {
                                vm.imageURL(
                                    for: $0,
                                    rowType: row.type,
                                    cwImage: cwImage,
                                    spoilerSafe: needsSpoilerSafeArtwork($0, cwImage: cwImage)
                                )
                            },
                            fallbackURLProvider: cwImage == .thumb
                                ? {
                                    vm.fallbackImageURL(
                                        for: $0,
                                        cwImage: cwImage,
                                        spoilerSafe: needsSpoilerSafeArtwork($0, cwImage: cwImage)
                                    )
                                }
                                : nil,
                            onItemSelected: { selectedItem = $0 },
                            cardStyle: row.type.cardStyle,
                            showsSeriesArtwork: cwImage != .still
                        )
                        .focused($focusedRowIndex, equals: idx)

                    case .tags(let tagRow):
                        TagRow(
                            title: tagRow.type.localizedTitle,
                            tags: tagRow.tags,
                            onTagSelected: { tagData in
                                selectedFilter = makeFilter(for: tagData, type: tagRow.type)
                            }
                        )
                        .focused($focusedRowIndex, equals: idx)

                    case .discoverProviders:
                        // Hide zero-match tiles. nil count = not yet computed, so first-run shows everything until the background precompute fills the dict and empties fade out.
                        let visibleProviders = CatalogProviders.networks.filter { provider in
                            let count = vm.providerItemCounts[provider.id]
                            return count == nil || count! > 0
                        }
                        if !visibleProviders.isEmpty {
                            CatalogProviderRow(
                                titleKey: HomeRowType.discoverProviders.localizedTitle,
                                providers: visibleProviders,
                                onSelect: { provider in
                                    selectedFilter = makeJellyfinFilter(for: provider)
                                },
                                backdropFor: { provider in
                                    vm.providerBackdrops[provider.id]
                                }
                            )
                            .focused($focusedRowIndex, equals: idx)
                        }

                    case .libraries(let libraries):
                        LibraryRow(
                            titleKey: HomeRowType.myMedia.localizedTitle,
                            libraries: libraries,
                            onSelect: { library in
                                selectedFilter = makeLibraryFilter(for: library)
                            }
                        )
                        .focused($focusedRowIndex, equals: idx)
                    }
                }
                }
                .padding(.vertical, 40)
            }
            .onChange(of: focusedRowIndex) { oldValue, newValue in
                // Scroll to top only on a real top-row → tab-bar arrival, gated two ways:
                // 1. oldValue == 0: the focus engine routes Up to the tab bar only from the top row; a row-N→nil (N>0) is a transient between LazyVStack row materializations, not a tab-bar arrival.
                // 2. 200ms debounce: even a legit row-0→tab-bar transition (and a down-scroll past row 0) passes through nil for a beat; 200ms outlasts those transients but still feels immediate.
                scrollResetTask?.cancel()
                guard newValue == nil, oldValue == 0 else { return }
                scrollResetTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
        }
    }

    /// Pairs a tile key with the session; nil before a user is resolved, which leaves the grid uncached rather than caching under a guess.
    private func cacheScope(_ key: String) -> FilterCacheScope? {
        appState.cacheIdentity.map { FilterCacheScope(key: key, identity: $0) }
    }

    private func makeJellyfinFilter(for provider: CatalogProvider) -> FilterDestination {
        // A provider tile filters the LOCAL library by Studio (pipe-joined aliases catch "Disney+" and "Walt Disney Pictures"), augmented by the smart-provider TMDB watch-provider hint so studio-tag-less titles surface (Modern Family on Disney+, Bluey via Ludo Studio).
        let region = Locale.current.region?.identifier ?? "US"
        return FilterDestination(
            title: provider.name,
            query: ItemQuery(
                includeItemTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 200,
                studioNames: provider.jellyfinStudioNames,
                // Card fields only, and the same set the provider precompute writes into this
                // tile's FilterCache entry: the grid and its pre-warmed cache must hold the same
                // shape of item, else a tap swaps one for the other (Sodalite#68).
                fields: JellyfinEndpoint.homeRowFields
            ),
            smartProviderID: provider.tmdbWatchProviderID,
            smartProviderRegion: region,
            cacheScope: cacheScope(FilterCacheKey.Home.provider(id: provider.id, region: region))
        )
    }

    private func makeFilter(for tag: TagCardData, type: HomeRowType) -> FilterDestination {
        FilterDestination(
            title: tag.name,
            query: ItemQuery(
                includeItemTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: 50,
                genres: [tag.name],
                // Mirrors precomputeGenreCaches, which pre-warms this exact cache key.
                fields: JellyfinEndpoint.homeRowFields
            ),
            // Without a cache scope FilteredGridView.init falls to the empty-state branch with isLoading=true on every visit (the brief flash on opening a genre tile). Tag name is a stable enough key, once the session is in the scope: "Action" is the same name on every server.
            cacheScope: cacheScope(FilterCacheKey.Home.genre(name: tag.name)),
            sortScope: sortServerID.map { LibrarySortScope.genre(name: tag.name, serverID: $0) }
        )
    }

    private func makeLibraryFilter(for library: JellyfinLibrary) -> FilterDestination {
        // My Media tile browses one library in the shared grid; parentID scopes it, types match the library.
        let types = MyMediaLibraries.itemTypes(for: library.libraryType)
        // Collapsing box sets inside the box-set view is meaningless, and a virtual view takes no parentID.
        let isVirtualView = MyMediaLibraries.isVirtualView(library.libraryType)
        // The only grids that defer to the server's "Group movies into collections" (Sodalite#44). Note the server itself skips collapsing once the grid's watch-status filter adds IsPlayed, so Watched/Unwatched stay flat.
        let grouping = HomeRowConfig.collectionGrouping(serverID: appState.activeServer?.id ?? appState.activeUser?.id ?? "")
        var query = ItemQuery(
            parentID: isVirtualView ? nil : library.id,
            includeItemTypes: types,
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 200,
            // A grid cell renders name/year/index/series/watched plus the poster; People,
            // MediaStreams, MediaSources, Chapters and Trickplay were fetched, decoded and cached
            // for every tile and never read (Sodalite#68).
            fields: JellyfinEndpoint.homeRowFields
        )
        if !isVirtualView {
            query.collapseBoxSetItems = grouping.queryValue
        }
        return FilterDestination(
            title: library.name,
            query: query,
            cacheScope: cacheScope(FilterCacheKey.Home.library(id: library.id, grouping: grouping)),
            sortScope: sortServerID.map { LibrarySortScope.library(id: library.id, serverID: $0) },
            hidesAudioPlaylists: MyMediaLibraries.hidesAudioPlaylists(library.libraryType)
        )
    }

    /// Server the sort choice is filed under; nil only before a session exists, which is also when no
    /// tile can be tapped.
    private var sortServerID: String? {
        appState.activeServer?.id ?? appState.activeUser?.id
    }
}

struct FilterDestination: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let query: ItemQuery
    /// TMDB watch-provider id augmenting the studio filter with Jellyseerr's live "streaming now" list, picking up studio-tag-less titles (Modern Family on Disney+, Suits on Netflix). nil runs only the studio match.
    var smartProviderID: Int?
    /// ISO 3166-1 alpha-2 region for smartProviderID; TMDB watch-provider data is region-specific (Disney+ DE != US), defaults to Locale.current.
    var smartProviderRegion: String?
    /// Where FilteredGridView caches this tile's results: the key, independent of smartProviderID so broadcast-only tiles (ABC/NBC/CBS) still cache and feed the empty-tile-hide pass, plus the session that fetched them. nil leaves the tile uncached.
    var cacheScope: FilterCacheScope?
    /// Where the grid's sort choice is stored (Sodalite#78); nil leaves the tile on Title A-Z without a control.
    var sortScope: LibrarySortScope?
    /// Playlists view only: drop the audio playlists the type filter cannot separate (see FilteredGridView).
    var hidesAudioPlaylists = false
}

extension ItemQuery: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(parentID)
        hasher.combine(sortBy)
        hasher.combine(genres)
        hasher.combine(studioNames)
    }

    static func == (lhs: ItemQuery, rhs: ItemQuery) -> Bool {
        lhs.parentID == rhs.parentID &&
        lhs.sortBy == rhs.sortBy &&
        lhs.genres == rhs.genres &&
        lhs.studioNames == rhs.studioNames &&
        lhs.isFavorite == rhs.isFavorite
    }
}

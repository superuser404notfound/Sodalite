import SwiftUI

struct HomeView: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
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

    /// Same latch for requestContentReload, and for the same reason: without it every reappear would
    /// reload the whole feed on a signal that was already answered.
    @State private var lastHandledContentReload = 0

    /// Presents the single-field sheet that fills the server's empty URL slot (iOS only; tvOS has
    /// no URL editor).
    @State private var showAddURLSheet = false

    /// True while something is presented over Home: a detail page or a filtered grid. Home is not
    /// the screen then, which is what the two refresh observers below ask about.
    private var isCovered: Bool { selectedItem != nil || selectedFilter != nil }

    var body: some View {
        ThemeNavigationStack {
            Group {
                if let vm = viewModel {
                    if let state = blockingState(vm: vm) {
                        ServerUnreachableView(
                            state: state,
                            serverName: appState.activeServer?.name ?? "",
                            onAddExternalAddress: addExternalAddressAction(for: state),
                            onRetry: { await retry(vm: vm) },
                            onOpenDownloads: dependencies.downloadStore.items.isEmpty ? nil : { appState.requestedTab = .downloads }
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
                    hidesAudioPlaylists: filter.hidesAudioPlaylists,
                    sources: filter.sources
                )
                // A My Media tile from a combined Home's secondary browses that server (Sodalite#85).
                .environment(\.serverSession, filter.serverID.map { dependencies.sessionRegistry.session(forServerID: $0) })
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
                    serverID: appState.activeServer?.id ?? userID,
                    sources: dependencies.homeSources(activeUserID: userID)
                )
                viewModel?.onUnauthorized = { [registry = dependencies.sessionRegistry] in registry.mute(serverID: $0) }
                Task { await viewModel?.loadContent() }
            } else {
                // Pick up new server-side content on the way back to the tab; the view model owns
                // the age that is worth a refetch, because the foreground observer below asks it
                // the same question.
                Task { await viewModel?.refreshIfStale(trigger: .tab) }
            }
        }
        // The app coming back to the foreground, which is the return `onAppear` does not cover: a
        // background round trip fires scenePhase transitions and nothing else (measured on tvOS
        // 26.5 and iOS 26.5). Without this, an Apple TV that slept with Sodalite open showed the
        // shelf from before it slept until the app was force quit (Sodalite#117).
        //
        // Not while something is presented over Home. The screen the user is actually on owns the
        // moment, and a fan-out landing on the shared request limiter next to a player that is
        // rebuilding its pipeline is the class of burst that starves a stream (Sodalite#12). The
        // observer below picks it up when the cover goes.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel?.refreshIfStale(trigger: .foreground, covered: isCovered) }
        }
        // Home becoming the screen again. A cover dismiss fires no `onAppear` either (measured,
        // iOS 26.5), so this is the other half of the same gate: what the user changed behind the
        // cover already arrives by notification, what passed in the meantime does not.
        .onChange(of: isCovered) { _, covered in
            guard !covered else { return }
            Task { await viewModel?.refreshIfStale(trigger: .coverDismissed) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeConfigDidChange)) { _ in
            viewModel?.reloadConfig()
            viewModel?.scheduleConfigReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeFavoritesDidChange)) { _ in
            // While something covers Home (detail/player), mark it stale instead of reloading now:
            // a fan-out landing on the shared limiter next to a player rebuilding its pipeline is the
            // class of burst that starves a stream (Sodalite#12, Audit 2026-09-25 BROWSE-1). The
            // `isCovered` observer above does the one reload once Home is the screen again.
            Task { @MainActor in
                if isCovered {
                    viewModel?.markDirty()
                } else {
                    await viewModel?.loadContent()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homePlayedDidChange)) { _ in
            Task { @MainActor in
                if isCovered {
                    viewModel?.markDirty()
                } else {
                    await viewModel?.loadContent()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidChange)) { note in
            // Patch the tile progress in place from the payload (race-free). While covered, that
            // patch is all this gets: the reload for structural changes (reorder, finished
            // drop-out) waits for the cover to actually go, instead of running once per auto-advance
            // right next to the player opening the next stream (Sodalite#12, Audit 2026-09-25
            // BROWSE-1). Not covered, reload now and re-apply so a stale cached re-fetch can't
            // regress the bar (issue #24).
            let itemID = note.userInfo?[PlaybackProgressKey.itemID] as? String
            let ticks = note.userInfo?[PlaybackProgressKey.positionTicks] as? Int64
            Task { @MainActor in
                if let itemID, let ticks {
                    viewModel?.applyPlaybackPosition(itemID: itemID, ticks: ticks)
                }
                if isCovered {
                    viewModel?.markDirty()
                    return
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
            Task { @MainActor in
                if isCovered {
                    viewModel?.markDirty()
                } else {
                    await viewModel?.loadContent()
                }
            }
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
                serverID: appState.activeServer?.id ?? userID,
                sources: dependencies.homeSources(activeUserID: userID)
            )
            viewModel?.onUnauthorized = { [registry = dependencies.sessionRegistry] in registry.mute(serverID: $0) }
            Task { await viewModel?.loadContent() }
        }
        // The participating servers changed (Combine servers switched, a server added or muted):
        // repaint from that set's cached feed, then fetch (Sodalite#85).
        .onChange(of: dependencies.sessionRegistry.participantsRevision) { _, _ in
            guard let userID = appState.activeUser?.id, let vm = viewModel else { return }
            let sources = dependencies.homeSources(activeUserID: userID)
            guard vm.acceptsSources(sources) else { return }
            Task { await vm.updateSources(sources) }
        }
        // No serverDidSwitch handler here: TabRootView is `.id(appState.activeServer?.id)`, so a
        // switch tears this whole view down and `.onAppear` above builds a fresh view model on the
        // destination identity, hydrated from its own cached feed (Audit 2026-09-25 BROWSE-3). A
        // handler here duplicated that first load and, on iOS where Settings stays a sheet over a
        // live Home, could fire against the outgoing view model before AppRouter's probe repointed
        // `activeServer`.
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
        // The fix for an off-network server, offered where the failure is (Sodalite#122).
        .addExternalAddressSheet(isPresented: $showAddURLSheet)
    }

    /// What Home shows instead of content, or nil to keep loading or keep showing rows.
    ///
    /// The rule is `ServerReachability.blockingState`, shared with the library grid so one question
    /// keeps one answer. What belongs to Home is only the reading of "has content" below.
    private func blockingState(vm: HomeViewModel) -> ServerReachability? {
        // A feed painted from disk is not evidence that the server answered (Sodalite#117), so the
        // verdict still speaks over it. Otherwise a cached shelf would stand in front of the
        // sentence that explains why none of its posters can load.
        let hasContent = !vm.tagRows.isEmpty || (!vm.rows.isEmpty && !vm.isShowingCachedFeed)
        return appState.serverReachability.blockingState(
            hasContent: hasContent,
            loadFailedEntirely: vm.loadFailedEntirely
        )
    }

    /// The add-an-external-address action, where there is both a slot to fill and a sheet to fill
    /// it in.
    ///
    /// tvOS has no URL editor at all, so there it stays nil and the screen offers Retry alone: a
    /// button that leads nowhere is worse than no button. The sentence above it is true on both.
    private func addExternalAddressAction(for state: ServerReachability) -> (() -> Void)? {
        ServerUnreachableView.addExternalAddressAction(
            state: state,
            server: appState.activeServer,
            present: { showAddURLSheet = true }
        )
    }

    /// Retry re-probes before it re-fetches, else the reload would run against the same stale
    /// verdict and paint this screen straight back.
    ///
    /// Only the probe is awaited. It settles in seconds and it is what decides whether this screen
    /// stays; the fan-out behind it needs the full round of request timeouts to give up on a server
    /// that is still down, and a Retry button that spins for three minutes would be the very bug
    /// this screen exists to remove.
    private func retry(vm: HomeViewModel) async {
        await dependencies.retryAfterFailure()
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
        let auth = ImageAuth.snapshot(dependencies.sessionRegistry)
        Task.detached(priority: .utility) {
            await ImageCache.prefetch(urls, auth: auth)
        }
    }

    private func contentView(vm: HomeViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Invisible zero-height scroll-to-top anchor for when focus leaves the rows.
                Color.clear.frame(height: 0).id("top")
                LazyVStack(alignment: .leading, spacing: 40) {
                    if !vm.unreachableServerNames.isEmpty {
                        CombinedHomeNotice(serverNames: vm.unreachableServerNames)
                    }
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
                                    [row.libraryName ?? "", vm.serverLabel(forRow: row)].compactMap { $0 }.joined(separator: " · ")
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
                            showsSeriesArtwork: cwImage != .still,
                            itemLabel: { vm.serverLabel(forItem: $0, in: row) }
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
                            label: { vm.serverLabel(forLibrary: $0) },
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
            .scrollsUnderShellChrome()
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

    /// A genre or provider tile's cache slot: the combined one when servers are combined, so the
    /// grid and the precompute that pre-warms it agree on one slot (Sodalite#85).
    private func homeTileScope(_ key: String) -> FilterCacheScope? {
        guard let vm = viewModel, vm.sources.count > 1 else { return cacheScope(key) }
        return FilterCacheScope(key: key, identity: vm.feedIdentity)
    }

    private var combinedSources: [HomeSource]? {
        guard let sources = viewModel?.sources, sources.count > 1 else { return nil }
        return sources
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
            cacheScope: homeTileScope(FilterCacheKey.Home.provider(id: provider.id, region: region)),
            sources: combinedSources
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
            cacheScope: homeTileScope(FilterCacheKey.Home.genre(name: tag.name)),
            sortScope: sortScopeID.map { LibrarySortScope.genre(name: tag.name, scope: $0) },
            sources: combinedSources
        )
    }

    private func makeLibraryFilter(for library: JellyfinLibrary) -> FilterDestination {
        // My Media tile browses one library in the shared grid; parentID scopes it, types match the library.
        let types = MyMediaLibraries.itemTypes(for: library.libraryType)
        // Collapsing box sets inside the box-set view is meaningless, and a virtual view takes no parentID.
        let isVirtualView = MyMediaLibraries.isVirtualView(library.libraryType)
        // The only grids that defer to the server's "Group movies into collections" (Sodalite#44). Note the server itself skips collapsing once the grid's watch-status filter adds IsPlayed, so Watched/Unwatched stay flat.
        let grouping = HomeRowConfig.collectionGrouping(scope: appState.profileKey?.storageScope ?? "")
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
        if MyMediaLibraries.browsesFolders(library.libraryType) {
            query = MyMediaLibraries.folderQuery(parentID: library.id)
        } else if !isVirtualView {
            query.collapseBoxSetItems = grouping.queryValue
        }
        return FilterDestination(
            title: library.name,
            query: query,
            cacheScope: FilterCacheScope(
                key: FilterCacheKey.Home.library(id: library.id, grouping: grouping),
                identity: viewModel?.gridIdentity(forLibrary: library) ?? appState.cacheIdentity
                    ?? CacheIdentity(serverID: "", userID: "")
            ),
            sortScope: sortScopeID.map { LibrarySortScope.library(id: library.id, scope: $0) },
            hidesAudioPlaylists: MyMediaLibraries.hidesAudioPlaylists(library.libraryType),
            serverID: viewModel?.sources.first(where: { $0.serverID == library.serverID && !$0.isActive })?.serverID
        )
    }

    /// Profile scope the sort choice is filed under; nil only before a session exists, which is also
    /// when no tile can be tapped.
    private var sortScopeID: String? {
        appState.profileKey?.storageScope
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
    /// The secondary server a combined Home's library tile belongs to; nil browses the active one.
    var serverID: String? = nil
    /// A combined Home's servers for a genre or provider tile; the grid pages through all of them.
    var sources: [HomeSource]? = nil

    // Identity is the per-instance id; the sources carry services, which have no equality.
    static func == (lhs: FilterDestination, rhs: FilterDestination) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

/// One quiet line above the shelf naming the servers that did not answer this round (Sodalite#85).
private struct CombinedHomeNotice: View {
    let serverNames: [String]

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    var body: some View {
        Text(String(
            format: String(localized: "home.serverUnreachable.format", defaultValue: "%@ is not reachable right now"),
            serverNames.formatted(.list(type: .and))
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.leading, metrics.rowLeading(shellPaysLeading: shellPaysLeading))
        .padding(.trailing, metrics.rowInset)
    }
}

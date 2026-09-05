import SwiftUI

@Observable
final class HomeViewModel {
    var rows: [HomeRowData] = []
    var tagRows: [HomeTagRowData] = []
    var isLoading = true
    /// Home's own verdict: the fan-out drained and not one row produced anything. Deliberately not
    /// a message. Home can only know THAT the load failed; WHY comes from
    /// `AppState.serverReachability`, which is measured once for the whole app and picks the copy
    /// and the actions (Sodalite#122). A localized `String?` here could carry neither, and could not
    /// be branched on by the offline-downloads state that becomes the second reader (#81).
    var loadFailedEntirely = false
    var rowConfigs: [HomeRowConfig] = []
    /// Sample backdrop per provider TMDB id from a one-shot Studios query so each provider tile shows a real library hero; nil falls back to logo-only.
    var providerBackdrops: [Int: URL] = [:]

    /// Resolved-item count per provider id from the background precompute; the home view's empty-tile-hide filter reads it to drop zero-match providers without the user tapping each one.
    var providerItemCounts: [Int: Int] = [:]

    /// Throttle against repeated precompute runs per session (re-resolving every provider on each Home re-appearance is ~100 Seerr calls for no perceptible gain). Internal so +Precompute can latch it.
    var providerCountsComputedAt: Date?

    /// Same throttle for the genre-tile pre-warm; grids still revalidate on open, this just paints the first post-tap frame from the file cache.
    var genreCachesComputedAt: Date?

    /// Coalescing window for config-change reloads; Home Customize posts one notification per toggle. Settable so tests don't wait it out.
    var configReloadDebounce: Duration = .milliseconds(800)
    private var configReloadTask: Task<Void, Never>?

    /// Handles for loadContent's background fan-outs, cancelled on teardown or re-entry, else an orphaned VM keeps fetching and writing FilterCache after its UI is gone.
    private var backdropTask: Task<Void, Never>?
    private var providerCountsTask: Task<Void, Never>?
    private var genreCachesTask: Task<Void, Never>?

    /// Last successful loadContent(); the view's onAppear uses it to decide whether to refresh, else new server-side content never shows until app restart.
    var lastLoadedAt: Date?

    /// Bumped on every loadContent entry; the for-await loop checks it before publishing so a re-entrant run (profile switch, refresh-while-loading) supersedes the older one instead of both writing rows/tagRows.
    private var loadGeneration: Int = 0

    // Internal (not private) so +Rows / +Precompute can reach the services + identity.
    let libraryService: JellyfinLibraryServiceProtocol
    let imageService: JellyfinImageService
    let discoverService: SeerrDiscoverServiceProtocol?
    let userID: String
    let serverID: String
    /// Scope for every FilterCache entry this view model pre-warms; the grids a tile opens read the same one.
    var cacheIdentity: CacheIdentity { CacheIdentity(serverID: serverID, userID: userID) }
    /// Libraries the My Media row offers: the video ones plus Collections and Playlists, which
    /// Jellyfin serves as views of their own. Populated by loadContent().
    var myMediaLibraries: [JellyfinLibrary] = []

    init(
        libraryService: JellyfinLibraryServiceProtocol,
        imageService: JellyfinImageService,
        discoverService: SeerrDiscoverServiceProtocol? = nil,
        userID: String,
        serverID: String
    ) {
        self.libraryService = libraryService
        self.imageService = imageService
        self.discoverService = discoverService
        self.userID = userID
        self.serverID = serverID
        self.rowConfigs = HomeRowConfig.loadFromStorage(serverID: serverID)
    }

    /// Reload after a config change, coalesced. Deliberately not a flag consumed by the view's onAppear: iOS presents Settings as a sheet over the tab bar, and a sheet dismiss fires no onAppear underneath, so a pending flag survived until relaunch (tvOS Settings is a tab, which did re-appear Home). Same reason the iCloud-sync poster needs this.
    func scheduleConfigReload() {
        configReloadTask?.cancel()
        configReloadTask = Task { [weak self] in
            guard let debounce = self?.configReloadDebounce else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.loadContent()
        }
    }

    isolated deinit {
        // Fan-outs hold self weakly, but a deferred-sleep task would linger up to 13 s after the VM is gone (profile switch); cancel flips Task.isCancelled so the next checkpoint stops early.
        configReloadTask?.cancel()
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
    }

    /// Patch a just-watched item's resume progress in place across every row holding it (issue #24). Mirrors the detail-side fix off the authoritative playback-stop payload so the Continue Watching progress bar is right immediately without racing a loadContent() re-fetch. loadContent() still runs for structural changes a patch can't make (re-ordering, dropping out once finished).
    @MainActor
    func applyPlaybackPosition(itemID: String, ticks: Int64) {
        for rowIndex in rows.indices {
            for itemIndex in rows[rowIndex].items.indices
            where rows[rowIndex].items[itemIndex].id == itemID {
                rows[rowIndex].items[itemIndex].setResumePosition(ticks)
            }
        }
    }

    /// Outcome of one entry in Home's fan-out.
    enum RowResult: Sendable {
        case media(HomeRowData)
        case tag(HomeTagRowData)
        /// Fetch succeeded and returned nothing: the row has to go, else it keeps showing what it held before (unfavoriting the last item left the stale card on screen until relaunch).
        case emptied(id: String, isTag: Bool)
        /// Fetch failed (loadRow/loadTagRow swallow errors and return nil): leave the on-screen row alone so a transient hiccup doesn't blank Home.
        case empty
        /// The server's library list, fetched inside the group rather than in front of it
        /// (Sodalite#122). It feeds row reconciliation and My Media, and nothing in the fan-out
        /// waits on it, so awaiting it first bought nothing and cost a full request timeout before
        /// a single row was even planned. On an unreachable server that was thirty seconds of dead
        /// time under a bare spinner, every launch. nil = the fetch failed and the stored config
        /// stands, which is the same fallback as before.
        case libraries([JellyfinLibrary]?)
    }

    /// One planned row, with everything the fetch needs already resolved.
    ///
    /// `isTag`, `type` and `id` are read while building this, on the MainActor: HomeRowConfig's
    /// row-type queries are MainActor-isolated under default isolation, so the escaping task body
    /// cannot reach them itself. A value rather than a prepared closure because the group takes an
    /// `@isolated(any)` operation, and a closure built here would carry this actor's isolation into
    /// the fan-out and serialize it.
    struct RowFetch: Sendable {
        let config: HomeRowConfig
        let isTag: Bool
        let type: HomeRowType
        let id: String
    }

    /// The rows this config actually fetches, in display order.
    ///
    /// Three kinds drop out: Discover provider rows and My Media render from state the fan-out does
    /// not produce, and in merged mode Next Up rides inside Continue Watching (see loadRow), so its
    /// standalone row goes while its config stays enabled and the toggle still restores it.
    func plannedRows(from configs: [HomeRowConfig]) -> [RowFetch] {
        configs
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { config in
                if config.type.isDiscoverProviderRow { return nil }
                if config.type == .myMedia { return nil }
                if config.type == .nextUp,
                   HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID) {
                    return nil
                }
                return RowFetch(
                    config: config,
                    isTag: config.type.isTagRow,
                    type: config.type,
                    id: config.id
                )
            }
    }

    /// Runs one planned row's fetch. Both scheduling sites go through it so the row added after
    /// reconciliation gets identical work to the ones planned up front.
    func fetch(_ entry: RowFetch) async -> RowResult {
        if entry.isTag {
            if let tagRow = await loadTagRow(type: entry.type) {
                return tagRow.tags.isEmpty ? .emptied(id: entry.id, isTag: true) : .tag(tagRow)
            }
        } else {
            if let rowData = await loadRow(config: entry.config) {
                return rowData.items.isEmpty ? .emptied(id: entry.id, isTag: false) : .media(rowData)
            }
        }
        return .empty
    }

    func loadContent() async {
        loadGeneration += 1
        let myGen = loadGeneration

        // Cancel previous fan-outs up front, not before scheduling new ones: the total-failure return below used to skip a late cancel, leaving old tasks fetching/writing FilterCache for a config being replaced.
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
        backdropTask = nil
        providerCountsTask = nil
        genreCachesTask = nil

        let isFirstLoad = rows.isEmpty && tagRows.isEmpty
        if isFirstLoad {
            isLoading = true
        }
        loadFailedEntirely = false

        // Row plans are built from the stored config; the server's library list only reconciles it.
        var plan = plannedRows(from: rowConfigs)
        var plannedIDs = Set(plan.map(\.id))

        // Drop rows disabled since the previous load instantly; still-enabled rows stay and get replaced in place as fresh results land.
        rows.removeAll { !plannedIDs.contains($0.id) }
        tagRows.removeAll { !plannedIDs.contains($0.id) }

        var sawAnyResult = false

        // Progressive publish: upsert each row as it completes so fast rows paint while the slowest (Latest on a huge library, 10+ s) streams. ForEach diffs by HomeRowData.id, so in-place replace preserves mounted AsyncImage state.
        await withTaskGroup(of: RowResult.self) { group in
            // The service and the id are lifted out of `self` here for the same reason the row
            // plan is: the task body runs off this actor and cannot read it.
            let libraryService = libraryService
            let userID = userID
            group.addTask {
                .libraries(try? await libraryService.getLibraries(userID: userID))
            }
            for entry in plan {
                group.addTask { [weak self] in await self?.fetch(entry) ?? .empty }
            }
            for await result in group {
                // Stale guard: a newer loadContent superseded this; drop the rest so we don't fight it for the rows array.
                guard loadGeneration == myGen else { return }
                switch result {
                case .media(let row):
                    if let idx = rows.firstIndex(where: { $0.id == row.id }) {
                        rows[idx] = row
                    } else {
                        rows.append(row)
                    }
                    sawAnyResult = true
                    isLoading = false
                    loadFailedEntirely = false
                case .tag(let row):
                    if let idx = tagRows.firstIndex(where: { $0.id == row.id }) {
                        tagRows[idx] = row
                    } else {
                        tagRows.append(row)
                    }
                    sawAnyResult = true
                    isLoading = false
                    loadFailedEntirely = false
                case .emptied(let id, let isTag):
                    if isTag {
                        tagRows.removeAll { $0.id == id }
                    } else {
                        rows.removeAll { $0.id == id }
                    }
                    // Counts as a result: the server answered, so this is not the total-failure case
                    // below. A server whose every row is legitimately empty must not read as offline.
                    sawAnyResult = true
                    isLoading = false
                    loadFailedEntirely = false
                case .empty:
                    break
                case .libraries(let libraries):
                    guard let libraries else {
                        LogTap.shared.note("Home: getLibraries failed, falling back to aggregated Latest rows")
                        break
                    }
                    // Reconciliation is additive (keeps user toggles/order); persist only on success so a transient failure can't wipe the dynamic rows.
                    myMediaLibraries = MyMediaLibraries.browsable(libraries)
                    let reconciled = HomeRowConfig.reconciled(stored: rowConfigs, libraries: libraries)
                    guard reconciled != rowConfigs else { break }
                    rowConfigs = reconciled
                    HomeRowConfig.saveToStorage(reconciled, serverID: serverID)

                    // Reconciliation can change the enabled set: a per-library row retired for
                    // redundancy hands its state to the aggregated row, and a row type new in this
                    // app version arrives with its default. Those rows were not in the plan, so
                    // fetch them here rather than making the user relaunch for them. Rows it
                    // dropped fall out of the on-screen set the same way a Customize toggle does.
                    plan = plannedRows(from: reconciled)
                    let reconciledIDs = Set(plan.map(\.id))
                    rows.removeAll { !reconciledIDs.contains($0.id) }
                    tagRows.removeAll { !reconciledIDs.contains($0.id) }
                    for entry in plan where !plannedIDs.contains(entry.id) {
                        group.addTask { [weak self] in await self?.fetch(entry) ?? .empty }
                    }
                    plannedIDs = reconciledIDs
                }
            }
        }

        guard loadGeneration == myGen else { return }

        let enabledRows = rowConfigs
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }

        // Total-failure path: loadRow/loadTagRow swallow errors and return nil, so "all nils" looks like "server unreachable". Surface the retry overlay only on first load; on refresh keep on-screen rows so a transient CDN hiccup doesn't wipe Home.
        //
        // This is the slow half of the verdict and it stays the fallback, not the primary: it can
        // only speak once the last row has given up, which on an unreachable server is one to three
        // minutes of request timeouts. `AppState.serverReachability` reaches the same conclusion in
        // about two seconds, and HomeView renders whichever arrives first (Sodalite#122).
        let hadConfiguredFetchableRows = !plan.isEmpty
        if hadConfiguredFetchableRows && !sawAnyResult && isFirstLoad {
            loadFailedEntirely = true
            isLoading = false
            return
        }

        isLoading = false
        lastLoadedAt = .now

        // Gate each background pass on its consuming row being enabled: the provider precompute is the heaviest query (one 10 000-item all-library scan + 33 per-provider resolves) and only the Discover row reads it, so hiding that row in Customize genuinely stops the scan (Sodalite#12 backend contention), not just the tiles.
        let providersEnabled = enabledRows.contains { $0.type.isDiscoverProviderRow }
        let genresEnabled = enabledRows.contains { $0.type == .genres }

        // All three deferred + .utility so secondary queries don't compete with the user's first detail navigation; staggered (3s/8s/13s) so the two heaviest don't land on the HTTPClient limiter at once and starve each other on a slow CDN (Sodalite#12).

        // One Studios query per provider for a sample backdrop; gaps tolerated (tile falls back to logo-only).
        if providersEnabled {
            backdropTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await self?.loadProviderBackdrops()
            }
        }
        // Pre-resolve provider tiles so the empty-tile-hide pass has data before the user taps each one. One run per session, heaviest of the three (10 000-item query + per-provider studio/TMDB matches), deferred longest.
        if providersEnabled {
            providerCountsTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { return }
                await self?.precomputeProviderCounts()
            }
        }
        // Pre-warm genre grids so the first tap renders from cache.
        if genresEnabled {
            genreCachesTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(13))
                if Task.isCancelled { return }
                await self?.precomputeGenreCaches()
            }
        }
    }

    /// Sodalite#66. `spoilerSafe` marks an item the veil would blur under the Backdrop and Thumb
    /// options, where the user asked for show art rather than the episode's own frame. Those two
    /// chains then stay on show-level art, which carries no plot, and the card drops the blur.
    func imageURL(
        for item: JellyfinItem,
        rowType: HomeRowType,
        cwImage: AppearancePreferences.ContinueWatchingImage = .still,
        spoilerSafe: Bool = false
    ) -> URL? {
        guard rowType.usesBackdrop else {
            return imageService.posterURL(for: item)
        }
        switch cwImage {
        case .still:
            if item.type == .episode {
                return imageService.episodeThumbnailURL(for: item)
            }
            // Landscape card is ~360pt (~720px @2x); request that, not the 1920 default,
            // to avoid decoding an 8MB backdrop into a small cell and thrashing the cache.
            return imageService.backdropURL(for: item, maxWidth: 720) ?? imageService.posterURL(for: item)
        case .backdrop:
            if spoilerSafe {
                return imageService.seriesArtworkURL(for: item, maxWidth: 720)
            }
            return imageService.backdropURL(for: item, maxWidth: 720)
                ?? imageService.episodeThumbnailURL(for: item)
                ?? imageService.posterURL(for: item)
        case .thumb:
            // Series Thumb by series id (tagless); paired with fallbackImageURL so a Thumb-less show degrades.
            let seriesID = item.type == .episode ? item.seriesId : nil
            if spoilerSafe {
                // Without a series id the item's own Thumb is the still again, so show art only.
                guard let seriesID else { return imageService.seriesArtworkURL(for: item, maxWidth: 720) }
                return imageService.imageURL(itemID: seriesID, imageType: .thumb, maxWidth: 720)
            }
            return imageService.imageURL(itemID: seriesID ?? item.id, imageType: .thumb, maxWidth: 720)
        }
    }

    /// Fallback under the Thumb option so a Thumb-less show degrades to backdrop/still. Nil for the other options (their primary URL already chains).
    func fallbackImageURL(
        for item: JellyfinItem,
        cwImage: AppearancePreferences.ContinueWatchingImage,
        spoilerSafe: Bool = false
    ) -> URL? {
        guard cwImage == .thumb else { return nil }
        if spoilerSafe {
            return imageService.seriesArtworkURL(for: item)
        }
        return imageService.backdropURL(for: item)
            ?? imageService.episodeThumbnailURL(for: item)
            ?? imageService.posterURL(for: item)
    }

    func reloadConfig() {
        rowConfigs = HomeRowConfig.loadFromStorage(serverID: serverID)
    }

    /// On active-server change: clear in-memory carousels (so the old server's posters don't linger) and reset the throttle guards so precompute reruns for the new library, then reload.
    @MainActor
    func reloadAfterServerSwitch() async {
        // Flip to loading before clearing rows so HomeView lands in the spinner branch, not the empty no-content branch.
        isLoading = true
        rows = []
        tagRows = []
        providerBackdrops = [:]
        providerItemCounts = [:]
        providerCountsComputedAt = nil
        genreCachesComputedAt = nil
        lastLoadedAt = nil
        await loadContent()
    }

    /// Returns the ordered list of all sections (media rows + tag rows + discover) in config order
    func orderedSections() -> [HomeSection] {
        let enabledConfigs = rowConfigs
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }

        return enabledConfigs.compactMap { config in
            if config.type.isDiscoverProviderRow {
                return .discoverProviders
            }
            if config.type == .myMedia {
                return myMediaLibraries.isEmpty ? nil : .libraries(myMediaLibraries)
            }
            if config.type.isTagRow {
                if let tagRow = tagRows.first(where: { $0.type == config.type }) {
                    return .tags(tagRow)
                }
            } else {
                if let row = rows.first(where: { $0.id == config.id }) {
                    return .media(row)
                }
            }
            return nil
        }
    }
}
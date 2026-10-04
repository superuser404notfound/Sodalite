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

    /// True while everything on screen came off disk and no fetch has answered yet (Sodalite#117).
    /// A painted shelf is otherwise indistinguishable from a server that replied, and two readers
    /// depend on telling those apart: the total-failure verdict below, which a cached feed must not
    /// silence, and `HomeView.blockingState`, which asks the same question one level up.
    private(set) var isShowingCachedFeed = false
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

    /// The library list of the load that is running, as one shared task rather than one fetch per
    /// reader: the fan-out consumes it to reconcile the row config, and Latest Shows awaits it for
    /// the library id its query needs. Internal so +Rows can reach it. nil between loads.
    var librariesTask: Task<[JellyfinLibrary]?, Never>?
    /// Every source's library list for the running load, by server id (Sodalite#85).
    var librariesTasks: [String: Task<[JellyfinLibrary]?, Never>] = [:]

    /// Where rows come from, active server first. One entry unless servers are combined.
    var sources: [HomeSource]
    /// How long a secondary server gets to answer before its slice is left out of a row.
    var secondaryDeadline: Duration = .seconds(4)
    /// Secondaries that failed or missed the deadline in the last finished load, by name.
    private(set) var unreachableServerNames: [String] = []
    /// The same, collected while a load runs.
    var pendingUnreachable: [String] = []
    /// Called with the server id of a secondary that refused its token.
    var onUnauthorized: ((String) -> Void)?
    /// The home feed's cache slot: the profile's own with one source, a combined one otherwise.
    var feedIdentity: CacheIdentity {
        sources.count > 1 ? Self.combinedIdentity(for: sources, userID: userID) : cacheIdentity
    }

    /// Last successful loadContent(); the staleness gate below reads it, else new server-side content never shows until app restart.
    var lastLoadedAt: Date?

    /// Age past which the shelf on screen is worth refetching. Tight enough to show additions fast,
    /// loose enough that tab-hopping does not spam the server.
    static let refreshStaleSeconds: TimeInterval = 60

    /// Refetch if what is on screen is older than that window, otherwise leave it alone.
    ///
    /// One gate, because two triggers ask the same question and must not drift: a return to the
    /// Home tab, which fires `onAppear`, and a return of the whole app to the foreground, which
    /// fires nothing of the sort. Measured with a throwaway SwiftUI app on tvOS 26.5 and iOS 26.5:
    /// a background round trip delivers `scenePhase` transitions and NOTHING else, no second
    /// `onAppear`, no `onDisappear`, no `.task` re-run. Home hung its only gate on `onAppear`, so a
    /// suspended app that came back had no path to refresh at all and sat on the shelf it loaded
    /// before the Apple TV went to sleep, for any length of time (Sodalite#117, DrHurt). The disk
    /// cache did not cause that and turning it off would not have fixed it: before it, the same
    /// resumed app showed the same stale rows out of memory.
    ///
    /// A view model that has never completed a load is deliberately NOT stale. Launch delivers the
    /// same transition into `.active` as a return does, and it delivers it while the first load is
    /// still in flight, so treating nil as stale would fan out twice on every launch. A load that
    /// failed leaves the previous timestamp standing, which is what lets the next return retry it.
    ///
    /// Every call writes one line to the diagnostic log, taken or declined, with the reason. A
    /// refresh and a skipped one used to leave identical logs, so "did Home refresh?" could only be
    /// answered by watching the screen (Sodalite#117, classicjazz, four captures in one round).
    func refreshIfStale(trigger: RefreshTrigger, covered: Bool = false) async {
        let decision = Self.refreshDecision(
            lastLoadedAt: lastLoadedAt, covered: covered, dirty: isDirty, now: Date()
        )
        LogTap.shared.note("[HomeRefresh] \(trigger.rawValue): \(decision.logText)")
        guard case .refetch = decision else { return }
        isDirty = false
        await loadContent()
    }

    /// True when a change landed while Home was covered and only got an in-place patch (favorited,
    /// watched, deleted, playback progress): the shelf may now be structurally wrong (reorder, a
    /// finished item dropping out) but nothing behind a cover is worth a fan-out landing next to
    /// whatever is covering it (Sodalite#12). The next `refreshIfStale` forces a refetch regardless
    /// of age and clears it, so the one reload the cover's dismissal delivers carries the change.
    private var isDirty = false

    /// Record a change Home only patched in place while covered, for the next `refreshIfStale` to
    /// pick up as a forced refetch.
    func markDirty() {
        isDirty = true
    }

    /// What asked the gate. Only the log reads it; the decision does not depend on it.
    enum RefreshTrigger: String {
        case tab = "back to the tab"
        case foreground = "app in the foreground"
        case coverDismissed = "cover dismissed"
    }

    enum RefreshDecision: Equatable {
        case refetch(ageSeconds: Int)
        case fresh(ageSeconds: Int)
        case covered(ageSeconds: Int?)
        case neverLoaded

        var logText: String {
            switch self {
            case .refetch(let age): "refetching, shelf is \(age)s old"
            case .fresh(let age): "declined, shelf is \(age)s old (window \(Int(HomeViewModel.refreshStaleSeconds))s)"
            case .covered(let age): "declined, something is presented over Home" + (age.map { " (shelf is \($0)s old)" } ?? "")
            case .neverLoaded: "declined, no load has completed yet"
            }
        }
    }

    /// Covered wins over age, so the one refresh the cover's dismissal is there to deliver is not
    /// spent next to a player that is still rebuilding its pipeline (Sodalite#12).
    static func refreshDecision(
        lastLoadedAt: Date?, covered: Bool, dirty: Bool = false, now: Date
    ) -> RefreshDecision {
        let age = lastLoadedAt.map { now.timeIntervalSince($0) }
        if covered { return .covered(ageSeconds: age.map { Int($0) }) }
        guard let age else { return .neverLoaded }
        if dirty { return .refetch(ageSeconds: Int(age)) }
        return age > refreshStaleSeconds ? .refetch(ageSeconds: Int(age)) : .fresh(ageSeconds: Int(age))
    }

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
    /// Where this profile's home rows, Next Up switches and grouping are stored.
    var homeScope: String { ProfileKey(serverID: serverID, userID: userID).storageScope }
    /// Libraries the My Media row offers: the video ones plus Collections and Playlists, which
    /// Jellyfin serves as views of their own. Populated by loadContent().
    var myMediaLibraries: [JellyfinLibrary] = []

    init(
        libraryService: JellyfinLibraryServiceProtocol,
        imageService: JellyfinImageService,
        discoverService: SeerrDiscoverServiceProtocol? = nil,
        userID: String,
        serverID: String,
        sources: [HomeSource]? = nil
    ) {
        self.libraryService = libraryService
        self.imageService = imageService
        self.discoverService = discoverService
        self.userID = userID
        self.serverID = serverID
        self.sources = sources ?? [HomeSource(
            serverID: serverID, serverName: "", userID: userID,
            libraryService: libraryService, isActive: true
        )]
        self.rowConfigs = HomeRowConfig.loadFromStorage(scope: ProfileKey(serverID: serverID, userID: userID).storageScope)
        hydrateFeedFromCache()
    }

    /// Paints the last feed this identity saw before the first request goes out (Sodalite#117).
    /// The entry is scoped per identity like every other FilterCache slice, so what lands here can
    /// only be this profile's own rows on this server, never the ones a switch is leaving behind.
    ///
    /// Rows the stored config no longer plans are dropped on the way in. loadContent prunes them
    /// too, but it does so a runloop turn later, which is long enough for a row disabled in
    /// Customize to flash on screen once per launch.
    private func hydrateFeedFromCache() {
        let cached = cachedFeed()
        // My Media is the one section with no fetched row behind it, so without the stored list it
        // was the only one still waiting a round trip while everything above it came off disk
        // (about a second behind the shelf, measured by classicjazz on the first build to carry the
        // cache). It is not evidence of anything: a list alone paints nothing, because Home is
        // still behind the spinner until a row lands.
        myMediaLibraries = cached.libraries
        guard !cached.rows.isEmpty else { return }
        rows = cached.rows
        isShowingCachedFeed = true
        isLoading = false
    }

    /// The persisted feed, minus rows the stored config no longer plans. Empty when there is
    /// nothing to paint, which both callers read as "behave the way this did before the cache".
    private func cachedFeed() -> FilterCache.HomeFeed {
        guard let cached = FilterCache.shared.homeFeed(identity: feedIdentity) else {
            return FilterCache.HomeFeed(rows: [], libraries: [])
        }
        let planned = Set(plannedRows(from: rowConfigs).map(\.id))
        return FilterCache.HomeFeed(
            rows: cached.rows.filter { planned.contains($0.id) },
            libraries: cached.libraries
        )
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
        // Fan-outs hold self weakly, also while their network work runs (see +Precompute), so this deinit is reached mid-pass; cancel flips Task.isCancelled so the next checkpoint stops early.
        configReloadTask?.cancel()
        backdropTask?.cancel()
        providerCountsTask?.cancel()
        genreCachesTask?.cancel()
        librariesTask?.cancel()
        librariesTasks.values.forEach { $0.cancel() }
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
                   HomeRowConfig.mergeContinueWatchingNextUp(scope: homeScope) {
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
            let rows = await fetchAcrossSources(entry.config)
            guard let first = rows.first else { return .empty }
            let items = HomeMerger.merge(
                rows.map(\.items),
                type: entry.type,
                mergedContinueWatching: HomeRowConfig.mergeContinueWatchingNextUp(scope: homeScope)
            )
            let merged = HomeRowData(
                type: first.type, items: items, libraryID: first.libraryID,
                libraryName: first.libraryName, serverID: rows.count == 1 ? first.serverID : nil
            )
            return merged.items.isEmpty ? .emptied(id: entry.id, isTag: false) : .media(merged)
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
        librariesTask?.cancel()
        librariesTasks.values.forEach { $0.cancel() }
        backdropTask = nil
        providerCountsTask = nil
        genreCachesTask = nil

        let isFirstLoad = rows.isEmpty && tagRows.isEmpty
        if isFirstLoad {
            isLoading = true
        }
        loadFailedEntirely = false
        pendingUnreachable = []

        // Row plans are built from the stored config; the server's library list only reconciles it.
        var plan = plannedRows(from: rowConfigs)
        var plannedIDs = Set(plan.map(\.id))

        // Drop rows disabled since the previous load instantly; still-enabled rows stay and get replaced in place as fresh results land.
        rows.removeAll { !plannedIDs.contains($0.id) }
        tagRows.removeAll { !plannedIDs.contains($0.id) }

        var sawAnyResult = false

        // One place for "the server answered", because the three cases that report it differ in
        // what they do with the payload, not in what the answer means. A cached feed stops being
        // the only thing on screen here too, which is what lets the verdict below stay honest.
        func serverAnswered() {
            sawAnyResult = true
            isLoading = false
            loadFailedEntirely = false
            isShowingCachedFeed = false
        }

        // Progressive publish: upsert each row as it completes so fast rows paint while the slowest (Latest on a huge library, 10+ s) streams. ForEach diffs by HomeRowData.id, so in-place replace preserves mounted AsyncImage state.
        await withTaskGroup(of: RowResult.self) { group in
            // One library list per source, started before the group because Latest Shows awaits
            // its own source's answer (see loadRow) and must not pay for a second request. The
            // group consumes the combined list as one result, so reconciliation is unchanged
            // (Sodalite#122, Sodalite#85).
            librariesTasks = [:]
            for source in sources {
                let service = source.libraryService
                let user = source.userID
                librariesTasks[source.serverID] = Task { try? await service.getLibraries(userID: user) }
            }
            librariesTask = librariesTasks[sources[0].serverID]
            let libraryTasks = Array(librariesTasks.values)
            group.addTask { [weak self] in
                // Unstructured, so cancelling the group has to be passed on by hand; without this
                // a torn-down Home would leave the requests running to completion.
                await withTaskCancellationHandler {
                    .libraries(await self?.combinedLibraries() ?? nil)
                } onCancel: {
                    libraryTasks.forEach { $0.cancel() }
                }
            }
            for entry in plan {
                group.addTask { [weak self] in await self?.fetch(entry) ?? .empty }
            }
            for await result in group {
                // Stale guard: a newer loadContent superseded this; drop the rest so we don't fight it for the rows array. A `withTaskGroup` body returning does not cancel the remaining children on its own, so without cancelAll() every row fetch of the superseded generation keeps running to completion on the shared limiter (Audit 2026-09-25 BROWSE-2).
                guard loadGeneration == myGen else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .media(let row):
                    if let idx = rows.firstIndex(where: { $0.id == row.id }) {
                        rows[idx] = row
                    } else {
                        rows.append(row)
                    }
                    serverAnswered()
                case .tag(let row):
                    if let idx = tagRows.firstIndex(where: { $0.id == row.id }) {
                        tagRows[idx] = row
                    } else {
                        tagRows.append(row)
                    }
                    serverAnswered()
                case .emptied(let id, let isTag):
                    if isTag {
                        tagRows.removeAll { $0.id == id }
                    } else {
                        rows.removeAll { $0.id == id }
                    }
                    // Counts as a result: the server answered, so this is not the total-failure case
                    // below. A server whose every row is legitimately empty must not read as offline.
                    serverAnswered()
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
                    HomeRowConfig.saveToStorage(reconciled, scope: homeScope)

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
        unreachableServerNames = pendingUnreachable

        let enabledRows = rowConfigs
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }

        // Total-failure path: loadRow/loadTagRow swallow errors and return nil, so "all nils" looks like "server unreachable". Surface the retry overlay only on first load; on refresh keep on-screen rows so a transient CDN hiccup doesn't wipe Home.
        //
        // This is the slow half of the verdict and it stays the fallback, not the primary: it can
        // only speak once the last row has given up, which on an unreachable server is one to three
        // minutes of request timeouts. `AppState.serverReachability` reaches the same conclusion in
        // about two seconds, and HomeView renders whichever arrives first (Sodalite#122).
        //
        // A feed painted from disk is not an answer, so `isShowingCachedFeed` keeps this branch
        // reachable on a launch that hydrated one (Sodalite#117). Without it Home would sit on last
        // week's shelf with every poster failing to load and no sentence saying why.
        let hadConfiguredFetchableRows = !plan.isEmpty
        if hadConfiguredFetchableRows && !sawAnyResult && (isFirstLoad || isShowingCachedFeed) {
            loadFailedEntirely = true
            isLoading = false
            return
        }

        isLoading = false
        lastLoadedAt = .now

        // Keep the shelf for the next launch and the next switch onto this identity (Sodalite#117).
        // Only where the server actually answered: the total-failure path returns above, and a
        // refresh that produced nothing must never replace a good entry with an empty one. On the
        // main actor like the precompute's writes, so a later read cannot overtake it.
        if sawAnyResult {
            // `myMediaLibraries` is whatever is on screen: the list this load fetched, or the
            // hydrated one where the library fetch alone failed. So a degraded load writes the
            // shelf back unchanged rather than emptying it.
            FilterCache.shared.setHomeFeed(rows, libraries: myMediaLibraries, identity: feedIdentity)
        }

        // Gate each background pass on its consuming row being enabled: the provider precompute is the heaviest query (one 10 000-item all-library scan + 33 per-provider resolves) and only the Discover row reads it, so hiding that row in Customize genuinely stops the scan (Sodalite#12 backend contention), not just the tiles.
        let providersEnabled = enabledRows.contains { $0.type.isDiscoverProviderRow }
        let genresEnabled = enabledRows.contains { $0.type == .genres }

        // All three deferred + .utility so secondary queries don't compete with the user's first detail navigation; staggered (3s/8s/13s) so the two heaviest don't land on the HTTPClient limiter at once and starve each other on a slow CDN (Sodalite#12).

        // One Studios query per provider for a sample backdrop; gaps tolerated (tile falls back to logo-only).
        if providersEnabled { scheduleProviderBackdrops(after: .seconds(3)) }
        // Pre-resolve provider tiles so the empty-tile-hide pass has data before the user taps each one. One run per session, heaviest of the three (10 000-item query + per-provider studio/TMDB matches), deferred longest.
        if providersEnabled { scheduleProviderCounts(after: .seconds(8)) }
        // Pre-warm genre grids so the first tap renders from cache.
        if genresEnabled { scheduleGenreCaches(after: .seconds(13)) }
    }

    func scheduleProviderBackdrops(after delay: Duration) {
        backdropTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await HomeViewModel.runProviderBackdrops { self }
        }
    }

    func scheduleProviderCounts(after delay: Duration) {
        providerCountsTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await HomeViewModel.runProviderCounts { self }
        }
    }

    func scheduleGenreCaches(after delay: Duration) {
        genreCachesTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await HomeViewModel.runGenreCaches { self }
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
        // Every chain here paints ONE landscape card, so every link asks for the same width,
        // the poster fallbacks included: a filled 2:3 image in a 16:9 slot is scaled by the
        // slot's width, not its own. Same width in `fallbackImageURL` below, so the two cannot
        // disagree about the cell they share (Sodalite#129).
        switch cwImage {
        case .still:
            if item.type == .episode {
                return imageService.episodeThumbnailURL(for: item)
            }
            return imageService.backdropURL(for: item, maxWidth: ImageWidth.wideCard)
                ?? imageService.posterURL(for: item, maxWidth: ImageWidth.wideCard)
        case .backdrop:
            if spoilerSafe {
                return imageService.seriesArtworkURL(for: item)
            }
            return imageService.backdropURL(for: item, maxWidth: ImageWidth.wideCard)
                ?? imageService.episodeThumbnailURL(for: item)
                ?? imageService.posterURL(for: item, maxWidth: ImageWidth.wideCard)
        case .thumb:
            // Series Thumb by series id (tagless); paired with fallbackImageURL so a Thumb-less show degrades.
            let seriesID = item.type == .episode ? item.seriesId : nil
            if spoilerSafe {
                // Without a series id the item's own Thumb is the still again, so show art only.
                guard let seriesID else { return imageService.seriesArtworkURL(for: item) }
                return imageService.imageURL(
                    itemID: seriesID, serverID: item.serverID, imageType: .thumb, maxWidth: ImageWidth.wideCard)
            }
            return imageService.imageURL(
                itemID: seriesID ?? item.id, serverID: item.serverID, imageType: .thumb, maxWidth: ImageWidth.wideCard)
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
        return imageService.backdropURL(for: item, maxWidth: ImageWidth.wideCard)
            ?? imageService.episodeThumbnailURL(for: item)
            ?? imageService.posterURL(for: item, maxWidth: ImageWidth.wideCard)
    }

    func reloadConfig() {
        rowConfigs = HomeRowConfig.loadFromStorage(scope: homeScope)
    }

    /// On active-server change: clear in-memory carousels (so the old server's posters don't linger) and reset the throttle guards so precompute reruns for the new library, then reload.
    @MainActor
    func reloadAfterServerSwitch() async {
        // Repaint from the destination's own cached feed rather than blanking to a spinner
        // (Sodalite#117). The blanking was there so the outgoing server's posters could not linger
        // under the new session, and that reason survives intact: the entry is read under this view
        // model's identity, so what lands is the destination's last shelf and never the one being
        // left. With nothing cached this behaves exactly as before, spinner included.
        let cached = cachedFeed()
        rows = cached.rows
        // The library list travels with them, and it is the half that had to be said out loud: it
        // lives in memory only, so a switch that kept it would leave the outgoing server's
        // libraries on screen and tappable under the new session, which is the exact thing the
        // blanking was there to prevent.
        myMediaLibraries = cached.libraries
        isShowingCachedFeed = !cached.rows.isEmpty
        isLoading = cached.rows.isEmpty
        tagRows = []
        unreachableServerNames = []
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
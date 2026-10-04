import Foundation
import Observation

@Observable
final class DetailViewModel {
    var item: JellyfinItem
    var isFavorite: Bool
    var isPlayed: Bool
    /// Played overrides keyed by item/episode/season ID; live-updates the watched badge without mutating the immutable JellyfinItem (same "pass state to the card" pattern as isFocused/isCurrent).
    var playedOverrides: [String: Bool] = [:]
    /// Favorite overrides keyed by episode ID; same reason as playedOverrides, the heart badge has to update without mutating the item.
    var favoriteOverrides: [String: Bool] = [:]
    var seasons: [JellyfinItem] = []
    var episodes: [JellyfinItem] = []
    /// Cache-miss episode fetch for the selected season in flight; drives the skeleton row instead of a blank ("grey then everything at once" slow-CDN symptom).
    var isLoadingEpisodes = false
    /// Season list still loading (no tabs yet); drives the skeleton season bar + episode row so the structure paints at the snapshot deadline instead of a blank gap on a slow CDN.
    var isLoadingSeasons = false
    var collectionItems: [JellyfinItem] = []
    var currentEpisodeID: String?
    /// Full next-up episode, populated when getNextUp lands; lets the play button render "S1E5 · 12:34" + resume bar before loadEpisodes fills `episodes` (else a flicker on the first focused tile).
    var nextUpEpisode: JellyfinItem?
    var similarItems: [JellyfinItem] = []
    /// Extras from the item's clips/extras folders (Sodalite#179). Fetched only when the detail reports a SpecialFeatureCount.
    var specialFeatures: [JellyfinItem] = []
    /// Similar titles the server does NOT have, from Jellyseerr. Empty unless the catalog is connected and visible, the item carries a TMDB id, and something survives the dedupe.
    var catalogSimilar: [SeerrMedia] = []
    var selectedSeasonID: String?
    var isLoading = false
    /// True once full-detail settles (success or failure). isLoading can flip false at the snapshot deadline while the detail roundtrip is still in flight, so views key overview/secondary placeholders on this to reserve space (Sodalite#15).
    var hasFullDetail = false
    /// Carries the id it was fetched for; see `PrefetchedPlaybackInfo`. Every writer below is a place
    /// where the play target moved without the prefetch following it (Sodalite#71).
    var cachedPlaybackInfo: PrefetchedPlaybackInfo?

    /// Server reported at least one local trailer; drives the Trailer button's visibility.
    var hasLocalTrailer: Bool {
        (item.localTrailerCount ?? 0) > 0
    }

    /// Season the tab bar currently has selected; the season synopsis box reads its overview.
    var selectedSeason: JellyfinItem? {
        selectedSeasonID.flatMap { id in seasons.first(where: { $0.id == id }) }
    }

    private let itemService: JellyfinItemServiceProtocol
    private let libraryService: JellyfinLibraryServiceProtocol?
    private let playbackService: JellyfinPlaybackServiceProtocol?
    /// The rung a play from this page would start on (Sodalite#87), read per prefetch so a network
    /// change between two prefetches is followed.
    private let streamingQuality: @MainActor () -> StreamingQuality
    private let imageService: JellyfinImageService
    /// nil when Seerr is not connected, or when the caller does not want a catalog row (collections, playlists).
    private let seerrMediaService: SeerrMediaServiceProtocol?
    private let userID: String
    /// Episode the detail was opened from (vs the series tile); loadSeasons lands on its season instead of running next-up logic.
    private let initialEpisode: JellyfinItem?
    /// In-flight season-prefetch task, cancelled on deinit so a disappearing view doesn't keep self alive.
    private var prefetchTask: Task<Void, Never>?
    /// Separate slot from prefetchTask: when shared, loadSeasons scheduling startSeasonPrefetch right after prefetchPlaybackInfo cancelled the PlaybackInfo fetch immediately, leaving cachedPlaybackInfo nil and the play button paying the full round trip.
    private var playbackInfoPrefetchTask: Task<Void, Never>?

    /// Per-season episode cache; an already-visited (or prefetched) season tab switches in instantly instead of a round trip.
    private var episodesCache: [String: [JellyfinItem]] = [:]

    /// Per-episode full-detail cache. The list is slim (no MediaStreams/MediaSources), so an episode opened into episode mode fetches full detail once for the TechInfoBox.
    private var episodeDetailCache: [String: JellyfinItem] = [:]

    isolated deinit {
        prefetchTask?.cancel()
        playbackInfoPrefetchTask?.cancel()
    }

    init(
        item: JellyfinItem,
        itemService: JellyfinItemServiceProtocol,
        imageService: JellyfinImageService,
        userID: String,
        libraryService: JellyfinLibraryServiceProtocol? = nil,
        playbackService: JellyfinPlaybackServiceProtocol? = nil,
        seerrMediaService: SeerrMediaServiceProtocol? = nil,
        initialEpisode: JellyfinItem? = nil,
        streamingQuality: @escaping @MainActor () -> StreamingQuality = { .original }
    ) {
        self.streamingQuality = streamingQuality
        self.item = item
        self.isFavorite = item.userData?.isFavorite ?? false
        self.isPlayed = item.userData?.played ?? false
        self.itemService = itemService
        self.libraryService = libraryService
        self.playbackService = playbackService
        self.imageService = imageService
        self.seerrMediaService = seerrMediaService
        self.userID = userID
        self.initialEpisode = initialEpisode
    }

    /// First local trailer to play, or nil; fetched on Trailer-button tap so the endpoint is hit on demand.
    func loadTrailer() async -> JellyfinItem? {
        let trailers = try? await itemService.getLocalTrailers(userID: userID, itemID: item.id)
        return trailers?.first
    }

    func loadFullDetail() async {
        // Episode deep-links arrive with the full episode in hand, enough to paint the first frame, so skip the loading gate and let seasons/cast/similar fade in (the episode path's "grey then everything at once" on slow CDNs). No next-up resolution runs here, so it's safe from the series-path repaint storm.
        isLoading = (initialEpisode == nil)

        let itemID = item.id
        let itemType = item.type

        // Avoid `async let`: @MainActor service calls crossing back into this non-isolated @Observable crash the task-local allocator with swift_task_dealloc_specific SIGABRT "freed pointer was not the last allocation". Task{}.value keeps each call on its own allocator while staying parallel.
        let detailTask = Task { try? await itemService.getItemDetail(userID: userID, itemID: itemID) }

        // Series content depends only on the item ID (already in hand), so run it parallel with the detail fetch and the play button's "Fortsetzen + S1E5 · 12:34" subtitle arrives with the rest of the panel.
        let seriesContentTask: Task<Void, Never>? = (itemType == .series) ? Task {
            await loadSeasons()
        } : nil
        let collectionContentTask: Task<Void, Never>? = (itemType == .boxSet) ? Task {
            await loadCollectionItems()
        } : nil
        let playlistContentTask: Task<Void, Never>? = (itemType == .playlist) ? Task {
            await loadPlaylistItems()
        } : nil

        // Similar items sit below the fold; fire without awaiting so they don't gate isLoading flipping false. Row appears progressively when the response lands.
        let snapshotTmdbID = item.tmdbID
        Task { [weak self] in
            guard let self else { return }
            let similar = try? await itemService.getSimilarItems(itemID: itemID, userID: userID, limit: 12)
            let libraryItems = similar?.items ?? []
            if similar != nil {
                await MainActor.run { self.similarItems = libraryItems }
            }
            // The catalog half waits for the detail fetch: the snapshot a Home row navigated with often
            // carries no ProviderIds, and the TMDB id is read off the fetched detail rather than off
            // self.item so it cannot race the outer assignment.
            let detail = await detailTask.value
            await self.loadCatalogSimilar(
                tmdbID: detail?.tmdbID ?? snapshotTmdbID,
                itemType: itemType,
                excluding: libraryItems
            )
        }

        // Snapshot-paint deadline (500ms): if the fetches haven't settled, flip isLoading=false and paint from the navigating-row JellyfinItem snapshot. Fast servers complete first and keep the quiet single-render path; slow CDN libraries (10+ s, Sodalite#12) stop showing the 30 s spinner and fade content in as fetches settle. Tradeoff: a brief field-fill repaint vs the hard wall (Sodalite#15).
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.isLoading else { return }
            self.isLoading = false
        }

        if let detail = await detailTask.value {
            item = detail
            isFavorite = detail.userData?.isFavorite ?? false
            isPlayed = detail.userData?.played ?? false
            if (detail.specialFeatureCount ?? 0) > 0 {
                loadSpecialFeatures(for: itemID)
            }
        }
        // Settled either way: on failure nothing more arrives, so placeholders must stop reserving space.
        hasFullDetail = true

        if itemType != .series && itemType != .boxSet && itemType != .playlist {
            prefetchPlaybackInfo(for: itemID)
        }

        // Wait on the parallel chains so isLoading flips false once every section has data (no-op if the deadline above already flipped it).
        await seriesContentTask?.value
        await collectionContentTask?.value
        await playlistContentTask?.value

        isLoading = false
    }

    /// Below the fold like the similar row, so it lands progressively instead of gating isLoading.
    private func loadSpecialFeatures(for itemID: String) {
        Task { [weak self] in
            guard let self else { return }
            let extras = (try? await itemService.getSpecialFeatures(userID: userID, itemID: itemID)) ?? []
            await MainActor.run { self.specialFeatures = extras }
        }
    }

    /// Catalog counterpart of the similar row: what Jellyseerr suggests and the server does not have.
    /// Recommendations first with a fallback to similar, the same order and reasoning as CatalogDetailView.
    /// Inert without a Seerr service (not connected, or the caller hid the catalog), without a TMDB id,
    /// and for anything that is not a movie or a series.
    private func loadCatalogSimilar(tmdbID: Int?, itemType: ItemType, excluding libraryItems: [JellyfinItem]) async {
        guard let seerrMediaService,
              let tmdbID,
              let mediaType = Self.seerrMediaType(for: itemType) else { return }

        let recommended = (try? await seerrMediaService.recommendations(mediaType: mediaType, tmdbID: tmdbID)) ?? []
        var candidates = SeerrLibraryDedupe.droppingAvailable(recommended)
        if candidates.isEmpty {
            let similar = (try? await seerrMediaService.similar(mediaType: mediaType, tmdbID: tmdbID)) ?? []
            candidates = SeerrLibraryDedupe.droppingAvailable(similar)
        }
        // Second net against the library row right above it: Jellyseerr's own sync can be stale or
        // unconfigured, and the same title in both rows is the thing this split was meant to end.
        let result = SeerrLibraryDedupe.removing(candidates, matching: libraryItems)
        await MainActor.run { self.catalogSimilar = result }
    }

    private static func seerrMediaType(for type: ItemType) -> SeerrMediaType? {
        switch type {
        case .movie: .movie
        case .series: .tv
        default: nil
        }
    }

    func loadSeasons() async {
        guard item.type == .series else { return }

        // Skeleton the season bar while getSeasons is in flight (the view shows the real section whenever seasons is non-empty, so the flip can't leave a skeleton over real content).
        isLoadingSeasons = true
        defer { isLoadingSeasons = false }

        // Three fetches keyed off the series ID: getSeasons (tabs), getNextUp (resume target), loadEpisodes (needs a season ID, which next-up supplies, so wait only on next-up, not on getSeasons).
        let seasonsTask = Task { try? await itemService.getSeasons(seriesID: item.id, userID: userID) }

        // Opened from a specific episode: land on its season and select it, skipping next-up selection. The view sets selectedEpisode = initialEpisode.
        if let initialEpisode, let seasonID = initialEpisode.seasonId {
            selectedSeasonID = seasonID
            await loadEpisodes(seasonID: seasonID)
            currentEpisodeID = initialEpisode.id
            prefetchPlaybackInfo(for: initialEpisode.id)
            if let seasonsResponse = await seasonsTask.value {
                seasons = seasonsResponse.items
            }
            startSeasonPrefetch()
            return
        }

        let nextUpTask: Task<JellyfinItemsResponse?, Never>? = libraryService.map { libService in
            Task { try? await libService.getNextUp(userID: userID, seriesID: item.id, limit: 1) }
        }

        // On next-up resolve: publish nextUpEpisode + fire loadEpisodes for its season parallel to the still-pending getSeasons, else the three round-trips serialise into the critical path.
        let earlyEpisodesTask: Task<Void, Never>? = nextUpTask.map { task in
            Task { @MainActor [weak self] in
                guard let self,
                      let nextEp = await task.value?.items.first else { return }
                self.nextUpEpisode = nextEp
                if let seasonID = nextEp.seasonId {
                    self.selectedSeasonID = seasonID
                    await self.loadEpisodes(seasonID: seasonID)
                    self.currentEpisodeID = nextEp.id
                    self.prefetchPlaybackInfo(for: nextEp.id)
                }
            }
        }

        // getSeasons is the slowest of the three (full metadata per season image tag).
        let seasonsResponse = await seasonsTask.value
        if let seasonsResponse {
            seasons = seasonsResponse.items
        }

        // Let the early-episodes task settle before the no-next-up fallback.
        await earlyEpisodesTask?.value

        // Fallback: no next-up means no watch history. Land on season 1 with episodes loaded so there's something to focus into.
        if nextUpEpisode == nil, episodes.isEmpty,
           let firstSeasonID = seasons.first?.id {
            selectedSeasonID = firstSeasonID
            await loadEpisodes(seasonID: firstSeasonID)
            if let firstEp = episodes.first?.id {
                prefetchPlaybackInfo(for: firstEp)
            }
        }

        startSeasonPrefetch()
    }

    /// Re-fetch seasons after a deletion. Unlike loadSeasons(), skips next-up/initial-episode selection: keeps the surviving selected season (else first remaining). Drops the whole episode cache (deleted seasons leave stale entries).
    func refreshSeasons() async {
        guard item.type == .series else { return }

        episodesCache.removeAll()

        guard let response = try? await itemService.getSeasons(seriesID: item.id, userID: userID) else {
            return
        }
        seasons = response.items
        let survivingSeasonIDs = Set(seasons.map(\.id))

        // The season Next Up was pointing at is gone: without this, Play kept the deleted episode
        // as its target (prefetched PlaybackInfo included) and launched a file the server just
        // removed (Audit 2026-09-25 BROWSE-7).
        if let nextUpSeasonID = nextUpEpisode?.seasonId, !survivingSeasonIDs.contains(nextUpSeasonID) {
            if currentEpisodeID == nextUpEpisode?.id { currentEpisodeID = nil }
            if cachedPlaybackInfo?.itemID == nextUpEpisode?.id { cachedPlaybackInfo = nil }
            nextUpEpisode = nil
        }

        // Keep the selected season if it survived, else the first remaining.
        let survivingSelection = selectedSeasonID.flatMap { id in
            seasons.first(where: { $0.id == id })?.id
        }
        if let seasonID = survivingSelection ?? seasons.first?.id {
            await loadEpisodes(seasonID: seasonID)
        } else {
            // Every season was deleted: nothing left to show.
            selectedSeasonID = nil
            episodes = []
        }
    }

    /// Re-fetch the resume position after playback so the Play button shows where the user stopped, not the launch spot (issue #24). Driven by .playbackProgressDidChange (posted once Jellyfin confirms PlaybackStopped). Lighter than loadFullDetail(): never touches isLoading so returning from the player doesn't reflash the spinner.
    func refreshResumePosition() async {
        // All observed-state assignments hop onto MainActor explicitly: with isLoading untouched (by design) the @Observable mutation is the only re-render trigger, and a continuation after a @MainActor service await resumes off-main on this non-isolated class, where an @Observable mutation doesn't reliably invalidate the view (issue #24 follow-up: model updated but Play-button timestamp stayed stale). loadFullDetail() escapes this only because it also flips isLoading.
        switch item.type {
        case .series:
            // Series Play resumes the next-up/current EPISODE, so position lives on the episode's userData. Refresh next-up + the on-screen season + drop the episode detail cache so an open panel re-enriches fresh.
            let nextUp = try? await libraryService?.getNextUp(userID: userID, seriesID: item.id, limit: 1)
            let seasonEpisodes: (seasonID: String, items: [JellyfinItem])?
            if let seasonID = selectedSeasonID,
               let response = try? await itemService.getEpisodes(seriesID: item.id, seasonID: seasonID, userID: userID) {
                seasonEpisodes = (seasonID, response.items)
            } else {
                seasonEpisodes = nil
            }
            await MainActor.run {
                episodeDetailCache.removeAll()
                if let next = nextUp?.items.first {
                    nextUpEpisode = next
                    currentEpisodeID = next.id
                }
                if let seasonEpisodes {
                    episodesCache[seasonEpisodes.seasonID] = seasonEpisodes.items
                    episodes = seasonEpisodes.items
                }
            }
        default:
            if let detail = try? await itemService.getItemDetail(userID: userID, itemID: item.id) {
                await MainActor.run {
                    item = detail
                    isFavorite = detail.userData?.isFavorite ?? false
                    isPlayed = detail.userData?.played ?? false
                }
            }
        }
    }

    /// Patch in-memory resume position for `itemID` straight from the playback-stop payload (issue #24). Deterministic counterpart to refreshResumePosition(): patches playbackPositionTicks on every in-memory copy rather than racing the server commit / ETag cache (re-fetch left the movie button stale ~10% and the episode button stale every time). Patches all holders (movie, next-up/current episode, loaded list, cached). @MainActor + synchronous so the @Observable mutation reliably re-renders.
    @MainActor
    func applyPlaybackPosition(itemID: String, ticks: Int64) {
        func patch(_ candidate: inout JellyfinItem) {
            guard candidate.id == itemID else { return }
            candidate.setResumePosition(ticks)
        }
        patch(&item)
        if var next = nextUpEpisode { patch(&next); nextUpEpisode = next }
        for index in episodes.indices { patch(&episodes[index]) }
        for index in collectionItems.indices { patch(&collectionItems[index]) }
        for (key, var list) in episodesCache {
            for index in list.indices { patch(&list[index]) }
            episodesCache[key] = list
        }
        if var cached = episodeDetailCache[itemID] {
            patch(&cached)
            episodeDetailCache[itemID] = cached
        }
    }

    /// A *arr upgrade rewrote the file behind an episode: Jellyfin ids items by path, so the library holds
    /// a NEW item and the id sitting in these lists is a corpse that fails playback again on the next tap.
    /// Swap it in place across the same holders `applyPlaybackPosition` patches; the player already has the
    /// authoritative replacement, so this needs no re-fetch.
    @MainActor
    func applyItemReplacement(staleID: String, newItem: JellyfinItem) {
        func swap(_ candidate: inout JellyfinItem) {
            guard candidate.id == staleID else { return }
            candidate = newItem
        }
        swap(&item)
        if var next = nextUpEpisode { swap(&next); nextUpEpisode = next }
        for index in episodes.indices { swap(&episodes[index]) }
        for (key, var list) in episodesCache {
            for index in list.indices { swap(&list[index]) }
            episodesCache[key] = list
        }
        // Overrides and the enriched copy described the file that is gone; the replacement carries its own
        // server-side state.
        episodeDetailCache[staleID] = nil
        playedOverrides[staleID] = nil
        favoriteOverrides[staleID] = nil
        if currentEpisodeID == staleID { currentEpisodeID = newItem.id }
        // The replacement is a different file, so the response fetched for the id that died describes
        // neither it nor its successor.
        if cachedPlaybackInfo?.itemID == staleID { cachedPlaybackInfo = nil }
    }

    func loadEpisodes(seasonID: String) async {
        selectedSeasonID = seasonID

        if let cached = episodesCache[seasonID] {
            episodes = cached
            isLoadingEpisodes = false
            // Keep warming, re-anchored on the season now on screen.
            startSeasonPrefetch()
            return
        }

        // Cache miss the user is waiting on: cancel the background prefetch first so it isn't holding HTTPClient slots this foreground fetch needs (the "switching to season 2 takes forever" regression).
        prefetchTask?.cancel()

        // Drop the prior season's list and show skeletons so the wrong season's episodes don't sit under the newly selected tab.
        episodes = []
        isLoadingEpisodes = true

        do {
            let response = try await itemService.getEpisodes(seriesID: item.id, seasonID: seasonID, userID: userID)
            episodesCache[seasonID] = response.items
            // A newer selection may have superseded this in-flight fetch (fast tab-mashing): keep the cache entry but don't clobber the on-screen season, and let the superseding call own the prefetch restart.
            guard selectedSeasonID == seasonID else { return }
            episodes = response.items
            isLoadingEpisodes = false
        } catch {
            guard selectedSeasonID == seasonID else { return }
            isLoadingEpisodes = false
        }

        // Foreground done: resume warming the remaining seasons, nearest first.
        startSeasonPrefetch()
    }

    /// (Re)start the background season prefetch, cancelling any prior run; called after the foreground season settles so prefetch trails the user instead of hogging the request budget.
    private func startSeasonPrefetch() {
        guard item.type == .series, seasons.count > 1 else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in await self?.prefetchRemainingSeasons() }
    }

    /// Warm the per-season episode cache for unopened seasons. Two properties learned from the regression where blanket prefetch starved the user-driven switch on slow CDNs:
    /// 1. Nearest-first: warm by distance from the on-screen season so the likely next pick is ready first.
    /// 2. Sequential + cancellable: one in-flight request leaves the HTTPClient budget free, and a cancel lands after at most one request, not a whole fan-out.
    func prefetchRemainingSeasons() async {
        guard item.type == .series else { return }

        // Yield the network to the foreground first-paint fetch first.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }

        let seriesID = item.id
        let uid = userID
        let service = itemService

        let order = seasons.map(\.id)
        let anchor = selectedSeasonID.flatMap { order.firstIndex(of: $0) } ?? 0
        let pending = order.enumerated()
            .filter { episodesCache[$0.element] == nil }
            .sorted { abs($0.offset - anchor) < abs($1.offset - anchor) }
            .map(\.element)

        for seasonID in pending {
            if Task.isCancelled { return }
            // A foreground switch may have cached this season meanwhile.
            guard episodesCache[seasonID] == nil else { continue }
            guard let response = try? await service.getEpisodes(seriesID: seriesID, seasonID: seasonID, userID: uid) else { continue }
            if Task.isCancelled { return }
            episodesCache[seasonID] = response.items
        }
    }

    /// Full episode detail (MediaStreams/MediaSources) for an episode opened into episode mode; the slim list lacks it. Cached per episode, falls back to the slim item on fetch failure.
    func enrichedEpisode(for episode: JellyfinItem) async -> JellyfinItem {
        if let cached = episodeDetailCache[episode.id] { return cached }
        guard let detail = try? await itemService.getItemDetail(userID: userID, itemID: episode.id) else {
            return episode
        }
        episodeDetailCache[episode.id] = detail
        return detail
    }

    func loadCollectionItems() async {
        guard item.type == .boxSet else { return }

        do {
            // Chronological oldest-first: franchise box-sets read in release order; SortName would put "Avengers" before "Iron Man". PremiereDate is Jellyfin's original theatrical/first-air date.
            let query = ItemQuery(
                parentID: item.id,
                sortBy: "PremiereDate,ProductionYear,SortName",
                sortOrder: "Ascending",
                limit: 50,
                // Full set on purpose: Play/Shuffle enqueue these members verbatim and the player
                // reads chapters, trickplay, mediaStreams and mediaSources off the queue entry
                // with no re-fetch (Sodalite#68).
                fields: JellyfinEndpoint.detailFields
            )
            let response = try await itemService.getCollectionItems(userID: userID, query: query)
            collectionItems = response.items
        } catch {
        }
    }

    func loadPlaylistItems() async {
        guard item.type == .playlist else { return }

        do {
            // No sortBy: keep the user's manual playlist order (sorting would defeat the purpose).
            // detailFields for the same reason as loadCollectionItems: the playlist's Play and
            // Shuffle buttons enqueue these items directly.
            let query = ItemQuery(parentID: item.id, limit: 200, fields: JellyfinEndpoint.detailFields)
            let response = try await itemService.getCollectionItems(userID: userID, query: query)
            collectionItems = response.items
        } catch {
            // Leave collectionItems empty; the view shows its empty state.
        }
    }

    func toggleFavorite() async {
        let oldValue = isFavorite
        isFavorite.toggle()

        do {
            try await itemService.setFavorite(userID: userID, itemID: item.id, isFavorite: isFavorite)
            NotificationCenter.default.post(name: .homeFavoritesDidChange, object: nil)
        } catch {
            isFavorite = oldValue
        }
    }

    /// Effective favorite state: in-session override wins over the server snapshot.
    func isFavorite(_ item: JellyfinItem) -> Bool {
        favoriteOverrides[item.id] ?? (item.userData?.isFavorite ?? false)
    }

    /// Toggle a single episode. `isFavorite` is the desired new state.
    func setEpisodeFavorite(_ episode: JellyfinItem, isFavorite: Bool) async {
        let oldValue = favoriteOverrides[episode.id]
        favoriteOverrides[episode.id] = isFavorite

        do {
            try await itemService.setFavorite(
                userID: userID, itemID: episode.id, isFavorite: isFavorite)
            NotificationCenter.default.post(name: .homeFavoritesDidChange, object: nil)
        } catch {
            favoriteOverrides[episode.id] = oldValue
        }
    }

    /// Effective played state: in-session override wins over the server snapshot.
    func isPlayed(_ item: JellyfinItem) -> Bool {
        playedOverrides[item.id] ?? (item.userData?.played ?? false)
    }

    /// Did the viewer mark this watched in THIS session? A narrower question than ``isPlayed(_:)``,
    /// and the only one the resume indicator may ask. An explicit mark-watched makes the server drop
    /// the item's resume position (`MarkPlayed` resets it), so the capsule has to go before the
    /// refetch; a `played` that arrived FROM the server alongside a position is a re-watch and keeps
    /// its capsule.
    func wasMarkedPlayedInSession(_ item: JellyfinItem) -> Bool {
        playedOverrides[item.id] == true
    }

    /// Toggle the top-level item (movie or whole series).
    func togglePlayed() async {
        let oldValue = isPlayed
        isPlayed.toggle()
        playedOverrides[item.id] = isPlayed

        do {
            try await itemService.setPlayed(userID: userID, itemID: item.id, isPlayed: isPlayed)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
            // Marking watched drops the item out of Resume and advances Next Up, so both
            // shelf sections are stale.
            TopShelfRefresher.invalidate()
        } catch {
            isPlayed = oldValue
            playedOverrides[item.id] = oldValue
        }
    }

    /// Toggle a single episode. `isPlayed` is the desired new state.
    func setEpisodePlayed(_ episode: JellyfinItem, isPlayed: Bool) async {
        let oldValue = playedOverrides[episode.id]
        playedOverrides[episode.id] = isPlayed

        do {
            try await itemService.setPlayed(userID: userID, itemID: episode.id, isPlayed: isPlayed)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
            // Marking watched drops the item out of Resume and advances Next Up, so both
            // shelf sections are stale.
            TopShelfRefresher.invalidate()
        } catch {
            playedOverrides[episode.id] = oldValue
        }
    }

    /// Toggle a whole season. The server cascades to children; we also flip the override for every loaded episode of that season so badges update live.
    func setSeasonPlayed(seasonID: String, isPlayed: Bool) async {
        var affected = Set((episodesCache[seasonID] ?? []).map(\.id))
        if selectedSeasonID == seasonID {
            affected.formUnion(episodes.map(\.id))
        }

        let previous = playedOverrides
        playedOverrides[seasonID] = isPlayed
        for id in affected { playedOverrides[id] = isPlayed }

        do {
            try await itemService.setPlayed(userID: userID, itemID: seasonID, isPlayed: isPlayed)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
            // Marking watched drops the item out of Resume and advances Next Up, so both
            // shelf sections are stale.
            TopShelfRefresher.invalidate()
        } catch {
            playedOverrides = previous
        }
    }

    // MARK: - Playback Info Pre-fetch

    func prefetchPlaybackInfo(for itemID: String) {
        guard let playbackService else { return }
        // Cancel any older prefetch, only the latest item matters.
        playbackInfoPrefetchTask?.cancel()
        // Drop the previous target's response before the new one is in flight: the play button can fire
        // inside that window, and a response that names a different item is worse than none.
        cachedPlaybackInfo = nil
        playbackInfoPrefetchTask = Task { [weak self] in
            guard let self else { return }
            let quality = self.streamingQuality()
            let response = try? await playbackService.getPlaybackInfo(
                itemID: itemID, userID: self.userID,
                profile: DirectPlayProfile.current(maxStreamingBitrate: quality.maxStreamingBitrate)
            )
            if Task.isCancelled { return }
            self.cachedPlaybackInfo = response.map {
                PrefetchedPlaybackInfo(itemID: itemID, quality: quality, response: $0)
            }
            // AetherEngine#551: the response is already in hand and the URL builders are pure, so
            // warming the source the play button would open costs no further round trip. This is the
            // cheapest warm in the app, and the one with the shortest odds: the viewer is looking at
            // the page whose play button opens exactly this.
            guard let response, let playbackService = self.playbackService,
                  let source = PlaybackStreamSelection.defaultSource(in: response) else { return }
            await PlaybackStreamSelection.warm(itemID: itemID, source: source, using: playbackService)
        }
    }

    func posterURL(for item: JellyfinItem) -> URL? {
        imageService.posterURL(for: item)
    }

    /// High-resolution poster for the full-bleed portrait hero: a phone screen at 3x, which is
    /// wider than any card and so has no family in `ImageWidth`. The card width fills it visibly
    /// upscaled.
    func heroPosterURL(for item: JellyfinItem) -> URL? {
        imageService.posterURL(for: item, maxWidth: 1290)
    }

    func backdropURL(for item: JellyfinItem) -> URL? {
        imageService.backdropURL(for: item)
    }
}

import Foundation

extension HomeViewModel {
    /// Runs with every Home load, so a changed mode in Customize Home lands with the row reload it
    /// already triggers. Discover keeps its picks across reloads of the same mode: a reshuffle on
    /// every return to the tab would swap the banner out from under someone about to tap it.
    func reloadHero() {
        let mode = HomeHeroMode.stored(scope: homeScope)
        recallHero(mode)
        if mode == .discover, heroLoadedMode == .discover, !heroItems.isEmpty { return }
        heroTask?.cancel()
        guard mode != .off else {
            heroItems = []
            heroLoadedMode = .off
            return
        }
        heroTask = Task { [weak self] in await self?.loadHero(mode) }
    }

    /// The banner's last titles per profile and mode, for this run of the app. Home is rebuilt from
    /// scratch on every return to the tab in the sidebar layout (the shell swaps its content), and
    /// sometimes with the top bar too; without this the banner then came back empty, refetched and
    /// faded its art in again, while the rows beside it repainted at once from their feed cache.
    private static var heroMemory: [String: [JellyfinItem]] = [:]

    private func heroMemoryKey(_ mode: HomeHeroMode) -> String { "\(homeScope)|\(mode.rawValue)" }

    /// Puts the remembered titles up before any request, the banner's half of `hydrateFeedFromCache`:
    /// this run's own first, else what the last run stored on disk. The disk copy is painted but not
    /// counted as loaded, so the request still goes out; that is what keeps Discover reshuffling on
    /// every launch, and a changed list then crossfades in rather than the banner popping in late and
    /// pushing the rows down.
    func recallHero(_ mode: HomeHeroMode? = nil) {
        let mode = mode ?? HomeHeroMode.stored(scope: homeScope)
        guard heroLoadedMode != mode, mode != .off else { return }
        if let remembered = Self.heroMemory[heroMemoryKey(mode)] {
            heroItems = remembered
            heroLoadedMode = mode
        } else if heroItems.isEmpty,
                  let stored = FilterCache.shared.homeFilterItems(
                      filterKey: FilterCacheKey.Home.hero(mode: mode.rawValue), identity: feedIdentity
                  ), !stored.isEmpty {
            heroItems = stored
        }
    }

    /// How many titles the carousel pages through.
    static let heroLimit = 8

    /// Movies and shows across every source, keeping only the ones with a backdrop: a hero without
    /// art is a black slab. Its own query rather than a row's, because that row may be switched off
    /// and asks for none of the overview, genre and rating fields the hero prints. A source that
    /// fails just contributes nothing; the rows report reachability.
    func loadHero(_ mode: HomeHeroMode) async {
        let query = Self.heroQuery(mode)
        let perSource = await withTaskGroup(of: [JellyfinItem].self) { group in
            for source in sources {
                group.addTask {
                    let items = (try? await source.libraryService.getItems(userID: source.userID, query: query))?.items ?? []
                    return items.map { item in
                        var stamped = item
                        if stamped.serverID == nil { stamped.serverID = source.serverID }
                        return stamped
                    }
                }
            }
            var all: [[JellyfinItem]] = []
            for await items in group { all.append(items) }
            return all
        }
        guard !Task.isCancelled else { return }
        let candidates = perSource.joined().filter { !($0.backdropImageTags ?? []).isEmpty }
        let ordered: [JellyfinItem] = switch mode {
        // ISO 8601 strings sort chronologically as text.
        case .recentlyAdded: candidates.sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }
        // Each server shuffled its own; shuffling again mixes the servers of a combined Home.
        case .discover, .favorites: candidates.shuffled()
        case .off: []
        }
        let fresh = Array(ordered.prefix(Self.heroLimit))
        // The same titles again leave the banner alone: a new array of the same pages would only
        // ask it to redraw what it already shows.
        if fresh.map(\.originKey) != heroItems.map(\.originKey) || heroLoadedMode != mode {
            heroItems = fresh
        }
        heroLoadedMode = mode
        Self.heroMemory[heroMemoryKey(mode)] = fresh
        // On the main actor, like the precompute's writes: eight items of JSON.
        FilterCache.shared.setHomeFilterItems(
            fresh, filterKey: FilterCacheKey.Home.hero(mode: mode.rawValue), identity: feedIdentity
        )
    }

    private static func heroQuery(_ mode: HomeHeroMode) -> ItemQuery {
        var query = ItemQuery(
            includeItemTypes: [.movie, .series],
            limit: heroLimit * 2,
            fields: JellyfinEndpoint.homeRowFields + ",Overview,Genres,OfficialRating,ProductionYear"
        )
        switch mode {
        case .recentlyAdded:
            query.sortBy = "DateCreated"
            query.sortOrder = "Descending"
        case .discover:
            query.sortBy = "Random"
            query.filters = ["IsUnplayed"]
        case .favorites:
            query.sortBy = "Random"
            query.isFavorite = true
        case .off:
            break
        }
        return query
    }

    func heroBackdropURL(for item: JellyfinItem) -> URL? {
        imageService.backdropURL(for: item, maxWidth: ImageWidth.fullBleed)
    }

    /// The portrait banner on iPhone stands the title's poster up instead of cropping a backdrop to a
    /// sliver. 1280 covers the widest iPhone at 3x (440pt is 1320px, cropped at the sides by the 4:5
    /// box); `fullBleed` decoded a 2:3 poster at 1920x2880, 22MB per page, and slowed every swipe.
    func heroPosterURL(for item: JellyfinItem) -> URL? {
        imageService.posterURL(for: item, maxWidth: 1280)
    }
}

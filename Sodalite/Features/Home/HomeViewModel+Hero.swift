import Foundation

extension HomeViewModel {
    /// Runs with every Home load, so a changed mode in Customize Home lands with the row reload it
    /// already triggers. Discover keeps its picks across reloads of the same mode: a reshuffle on
    /// every return to the tab would swap the banner out from under someone about to tap it.
    func reloadHero() {
        let mode = HomeHeroMode.stored(scope: homeScope)
        if mode == .discover, heroLoadedMode == .discover, !heroItems.isEmpty { return }
        heroTask?.cancel()
        guard mode != .off else {
            heroItems = []
            heroLoadedMode = .off
            return
        }
        heroTask = Task { [weak self] in await self?.loadHero(mode) }
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
        heroItems = Array(ordered.prefix(Self.heroLimit))
        heroLoadedMode = mode
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

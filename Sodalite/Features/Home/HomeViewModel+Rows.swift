import SwiftUI

// MARK: - Per-Row Fetching

extension HomeViewModel {

    /// /Items/Latest (GroupItems default) returns a bare Episode when a series gained exactly one new episode; only multi-episode batches fold into the Series. Replace each episode with its parent series (one batched Ids lookup) and dedupe; on lookup failure fall back to the unfolded items rather than going empty.
    private func foldEpisodesIntoSeries(_ items: [JellyfinItem]) async -> [JellyfinItem] {
        let seriesIDs = items.compactMap { $0.type == .episode ? $0.seriesId : nil }
        guard !seriesIDs.isEmpty else { return items }

        let query = ItemQuery(
            ids: Array(Set(seriesIDs)),
            fields: JellyfinEndpoint.homeRowFields
        )
        guard let response = try? await libraryService.getItems(userID: userID, query: query) else {
            return items
        }
        let seriesByID = Dictionary(
            response.items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Fold-local: N episodes of one series map to N copies of that series item. It is NOT the
        // row's uniqueness guarantee, which lives in HomeRowData's init, because this whole function
        // returns early when the list carries no episodes at all.
        var seen = Set<String>()
        var folded: [JellyfinItem] = []
        for item in items {
            let mapped: JellyfinItem
            if item.type == .episode, let seriesID = item.seriesId, let series = seriesByID[seriesID] {
                mapped = series
            } else {
                mapped = item
            }
            if seen.insert(mapped.id).inserted {
                folded.append(mapped)
            }
        }
        return folded
    }

    func loadRow(config: HomeRowConfig) async -> HomeRowData? {
        do {
            let type = config.type
            let items: [JellyfinItem]

            switch type {
            case .continueWatching:
                let response = try await libraryService.getResumeItems(userID: userID, mediaType: "Video", limit: 16)
                if HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID) {
                    // Combined row: resume items, then Next Up. Next Up already excludes resumables server-side (EnableResumable=false); the id dedupe is belt-and-suspenders. Next Up failing must not take resume items down (try?).
                    let rewatching = HomeRowConfig.enableRewatchingNextUp(serverID: serverID)
                    let nextUp = (try? await libraryService.getNextUp(userID: userID, seriesID: nil, limit: 16, rewatching: rewatching))?.items ?? []
                    var seen = Set(response.items.map(\.id))
                    items = response.items + nextUp.filter { seen.insert($0.id).inserted }
                } else {
                    items = response.items
                }

            case .nextUp:
                let rewatching = HomeRowConfig.enableRewatchingNextUp(serverID: serverID)
                let response = try await libraryService.getNextUp(userID: userID, seriesID: nil, limit: 16, rewatching: rewatching)
                items = response.items

            case .latestMovies:
                // Native /Items/Latest for web-UI parity. ParentId omitted so multiple movie libraries all surface, which makes IncludeItemTypes=Movie mandatory (else Jellyfin jumbles movies/series/music into one row).
                items = try await libraryService.getLatestMedia(
                    userID: userID,
                    parentID: nil,
                    includeItemTypes: [.movie],
                    limit: 16
                )

            case .latestShows:
                // Per-library fan-out, not one typed aggregate: IncludeItemTypes=Series,Episode filters before grouping, so episode bursts from a few shows crowd out everything else (device reports 2026-06-11). ParentId-only queries group reliably (Sodalite#12). Round-robin interleave approximates global recency (a grouped entry carries the SERIES' DateCreated, not the new episode's, so it can't sort).
                let showLibraries = myMediaLibraries.filter { ($0.collectionType ?? "") == "tvshows" }
                if showLibraries.isEmpty {
                    // getLibraries failed: fall back to the typed aggregate, imperfect but better than empty.
                    let latest = try await libraryService.getLatestMedia(
                        userID: userID,
                        parentID: nil,
                        includeItemTypes: [.series, .episode],
                        limit: 64
                    )
                    items = Array(await foldEpisodesIntoSeries(latest).prefix(16))
                } else {
                    var lists: [[JellyfinItem]] = []
                    for library in showLibraries {
                        let list = (try? await libraryService.getLatestMedia(
                            userID: userID,
                            parentID: library.id,
                            includeItemTypes: nil,
                            limit: 16
                        )) ?? []
                        lists.append(list)
                    }
                    var merged: [JellyfinItem] = []
                    let deepest = lists.map(\.count).max() ?? 0
                    for index in 0..<deepest {
                        for list in lists where index < list.count {
                            merged.append(list[index])
                        }
                    }
                    items = Array(await foldEpisodesIntoSeries(merged).prefix(16))
                }

            case .allMovies:
                let query = ItemQuery(
                    includeItemTypes: [.movie],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .allSeries:
                let query = ItemQuery(
                    includeItemTypes: [.series],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .favorites:
                let query = ItemQuery(
                    includeItemTypes: [.movie, .series, .boxSet],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    isFavorite: true,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .favoriteEpisodes:
                // Series/season/episode sort keeps several favorites of one show adjacent; no
                // foldEpisodesIntoSeries here, the individual episode is the point of the row.
                let query = ItemQuery(
                    includeItemTypes: [.episode],
                    sortBy: "SeriesSortName,ParentIndexNumber,IndexNumber",
                    sortOrder: "Ascending",
                    limit: 30,
                    isFavorite: true,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .topRatedMovies:
                let query = ItemQuery(
                    includeItemTypes: [.movie],
                    sortBy: "CommunityRating",
                    sortOrder: "Descending",
                    limit: 20,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .topRatedShows:
                let query = ItemQuery(
                    includeItemTypes: [.series],
                    sortBy: "CommunityRating",
                    sortOrder: "Descending",
                    limit: 20,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .recentlyAdded:
                let query = ItemQuery(
                    includeItemTypes: [.movie, .series],
                    sortBy: "DateCreated",
                    sortOrder: "Descending",
                    limit: 20,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .recentlyReleasedMovies:
                let response = try await libraryService.getItems(
                    userID: userID,
                    query: HomeReleaseRowQuery.movies(now: Date(), limit: 20)
                )
                items = HomeReleaseRowQuery.airedOnly(response.items)

            case .recentlyReleasedShows:
                // Episodes folded onto their series, so a show that aired last night ranks by that
                // episode rather than by the date the show first started (see HomeReleaseRowQuery).
                let response = try await libraryService.getItems(
                    userID: userID,
                    query: HomeReleaseRowQuery.episodes(now: Date(), limit: 64)
                )
                let aired = HomeReleaseRowQuery.airedOnly(response.items)
                items = Array(await foldEpisodesIntoSeries(aired).prefix(16))

            case .collections:
                let query = ItemQuery(
                    includeItemTypes: [.boxSet],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 30,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = response.items

            case .playlists:
                // Over-fetch: audio playlists are dropped below, and Jellyfin has no server-side
                // filter for them that is reliable across versions (MediaType on a Playlist is a
                // computed property, so `MediaTypes=` cannot be counted on).
                let query = ItemQuery(
                    includeItemTypes: [.playlist],
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    limit: 60,
                    fields: JellyfinEndpoint.homeRowFields
                )
                let response = try await libraryService.getItems(userID: userID, query: query)
                items = Array(response.items.filter { !$0.isAudioPlaylist }.prefix(30))

            case .libraryLatest:
                // Per-library Latest scoped by parentID alone. Deliberately NO IncludeItemTypes: it would filter before GroupItems grouping, collapsing an episodes-only library to one tile (Sodalite#12, DrHurt "latest in Series - French only loads 1 item"). ParentId already constrains the library, so the type hint the aggregate rows need (they drop ParentId) is the bug here.
                guard let libraryID = config.libraryID else { return nil }
                // Over-fetch + post-fold cap (latestShows rationale): the fold can dedupe a series against its own episodes, shrinking the row below 16.
                let latest = try await libraryService.getLatestMedia(
                    userID: userID,
                    parentID: libraryID,
                    includeItemTypes: nil,
                    limit: 24
                )
                items = Array(await foldEpisodesIntoSeries(latest).prefix(16))

            case .myMedia, .genres, .discoverProviders:
                return nil
            }

            return HomeRowData(
                type: type,
                items: items,
                libraryID: config.libraryID,
                libraryName: config.libraryName
            )
        } catch {
            return nil
        }
    }

    func loadTagRow(type: HomeRowType) async -> HomeTagRowData? {
        do {
            let tags: [NamedItem]
            switch type {
            case .genres:
                let allGenres = try await libraryService.getGenres(userID: userID)
                tags = allGenres.filter { GenreFilter.isPrimary($0.name) }
            default:
                return nil
            }

            let tagItems: [(String, JellyfinItem?)] = await withTaskGroup(
                of: (String, JellyfinItem?).self,
                returning: [(String, JellyfinItem?)].self
            ) { group in
                // Bounded fan-out: at most maxConcurrent backdrop queries at a time, not all ~15-20 up front, so a genre-heavy library doesn't burst the HTTPClient limiter on first load.
                var iter = tags.makeIterator()
                let maxConcurrent = 6

                func enqueue(_ tag: NamedItem) {
                    group.addTask {
                        let query = ItemQuery(
                            includeItemTypes: [.movie, .series],
                            sortBy: "Random",
                            limit: 1,
                            genres: [tag.name],
                            fields: JellyfinEndpoint.homeRowFields
                        )
                        let item = try? await self.libraryService.getItems(userID: self.userID, query: query).items.first
                        return (tag.id, item)
                    }
                }

                for _ in 0..<maxConcurrent {
                    guard let next = iter.next() else { break }
                    enqueue(next)
                }
                var results: [(String, JellyfinItem?)] = []
                for await result in group {
                    results.append(result)
                    if let next = iter.next() { enqueue(next) }
                }
                return results
            }

            // Build cards on MainActor (image URL construction needs it)
            let itemMap = Dictionary(uniqueKeysWithValues: tagItems)
            // Only surface genres that actually have movie/series content; the per-genre probe above
            // returns nil for empty genres, so drop those instead of rendering dead tiles.
            let cardData: [TagCardData] = tags.compactMap { tag in
                guard let item = itemMap[tag.id].flatMap({ $0 }) else { return nil }
                // Genre/tag tile is ~320pt (~640px @2x); avoid the 1920 backdrop default.
                let backdropURL = imageService.backdropURL(for: item, maxWidth: 640) ?? imageService.posterURL(for: item)
                return TagCardData(id: tag.id, name: tag.name, backdropURL: backdropURL)
            }

            return HomeTagRowData(type: type, tags: cardData)
        } catch {
            return nil
        }
    }
}

import Foundation

/// Builds a shuffled play queue from a `SortBy=Random` query for the shuffle
/// buttons. ItemQuery always sends `Recursive=true`, so a series id returns
/// random episodes across seasons and a folder returns random leaf items.
enum VideoShuffleQueue {

    /// Queue cap; 200 = hundreds of hours, so no refill on reaching the end.
    static let defaultLimit = 200

    /// Fetches up to `limit` random `itemTypes` under `parentID`. `baseQuery`
    /// (if given) is the starting query with sort/type/paging/filter
    /// overridden. Empty array on any failure (caller no-ops).
    static func build(
        parentID: String?,
        baseQuery: ItemQuery? = nil,
        itemTypes: [ItemType],
        limit: Int = defaultLimit,
        service: JellyfinLibraryServiceProtocol,
        userID: String
    ) async -> [JellyfinItem] {
        var query = baseQuery ?? ItemQuery(fields: JellyfinEndpoint.detailFields)
        if let parentID { query.parentID = parentID }
        query.includeItemTypes = itemTypes
        query.sortBy = "Random"
        query.sortOrder = nil
        query.limit = limit
        query.startIndex = nil
        // Shuffle ignores the watch-status filter per the feature spec (Sodalite#17); what the
        // filter menu put there (favorites, continue watching) stays.
        query.filters = withoutWatchFilter(query.filters)
        // A library grid may defer collection grouping to the server (Sodalite#44); a collapsed BoxSet in the queue is not playable, so shuffle always takes the flat list.
        query.collapseBoxSetItems = false
        // A folder-browsed grid lists one level; its shuffle draws from the whole tree beneath it (Sodalite#180).
        query.recursive = true
        // Never inherit the grid's card-sized field set: these items go to PlayerViewModel as they
        // are, including on auto-advance, and it reads chapters/trickplay/mediaStreams/mediaSources
        // straight off the queue entry (Sodalite#68).
        query.fields = JellyfinEndpoint.detailFields
        let response = try? await service.getItems(userID: userID, query: query)
        return response?.items ?? []
    }

    /// How many matching series a filtered shows shuffle draws from.
    static let seriesSampleSize = 20

    /// A shows grid narrowed by the filter menu (Sodalite#252). The menu describes series, and
    /// their genre, rating, status or year does not carry onto episodes (Jellyfin 12.2 answers
    /// `IncludeItemTypes=Episode&Genres=Animation` with nothing). So the matching series are drawn
    /// first, then random episodes from each, mixed.
    static func buildFromSeries(
        seriesQuery: ItemQuery,
        limit: Int = defaultLimit,
        service: JellyfinLibraryServiceProtocol,
        userID: String
    ) async -> [JellyfinItem] {
        var query = seriesQuery
        query.includeItemTypes = [.series]
        query.sortBy = "Random"
        query.sortOrder = nil
        query.limit = seriesSampleSize
        query.startIndex = nil
        query.filters = withoutWatchFilter(query.filters)
        query.collapseBoxSetItems = false
        query.recursive = true
        query.fields = ""
        guard let series = try? await service.getItems(userID: userID, query: query).items,
              !series.isEmpty else { return [] }
        let perSeries = max(1, limit / series.count)
        let episodes = await withTaskGroup(of: [JellyfinItem].self) { group in
            for show in series {
                group.addTask {
                    await build(parentID: show.id, itemTypes: [.episode], limit: perSeries, service: service, userID: userID)
                }
            }
            var all: [JellyfinItem] = []
            for await batch in group { all += batch }
            return all
        }
        return Array(episodes.shuffled().prefix(limit))
    }

    private static func withoutWatchFilter(_ filters: [String]?) -> [String]? {
        let kept = (filters ?? []).filter { $0 != "IsPlayed" && $0 != "IsUnplayed" }
        return kept.isEmpty ? nil : kept
    }
}

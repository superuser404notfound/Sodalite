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
        // Shuffle ignores the watch-status filter per the feature spec.
        query.filters = nil
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
}

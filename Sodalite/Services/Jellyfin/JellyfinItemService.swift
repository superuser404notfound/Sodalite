import Foundation

/// `MovieCatalogQuerying` (getCollectionItems / findByProviderIDs) is inherited: resolving a replaced
/// movie needs those two and nothing else, and a narrow face keeps it testable.
protocol JellyfinItemServiceProtocol: MovieCatalogQuerying {
    func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem
    /// Local trailers; bare array response (not the {Items:[...]} envelope), possibly empty.
    func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem]
    /// Extras (clips, featurettes, deleted scenes, ...); bare array response, possibly empty.
    func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem]
    func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse
    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse
    func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse
    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws
    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws
    /// Resolves a library item by TMDB id; first verified match or nil. `searchTerm` narrows the candidate set (see findByProviderIDs).
    func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem?
    /// People matching a name, carrying ProviderIds so the caller can tell same-named people apart. People live in their own namespace, so an /Items search never returns them.
    func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem]
    func deleteItem(itemID: String) async throws
}

final class JellyfinItemService: JellyfinItemServiceProtocol {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
        try await client.request(
            endpoint: JellyfinEndpoint.itemDetail(userID: userID, itemID: itemID),
            responseType: JellyfinItem.self
        )
    }

    func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] {
        let response: LossyJellyfinItems = try await client.request(
            endpoint: JellyfinEndpoint.localTrailers(userID: userID, itemID: itemID),
            responseType: LossyJellyfinItems.self
        )
        return response.elements
    }

    func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] {
        let response: LossyJellyfinItems = try await client.request(
            endpoint: JellyfinEndpoint.specialFeatures(userID: userID, itemID: itemID),
            responseType: LossyJellyfinItems.self
        )
        return response.elements
    }

    func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.seasons(seriesID: seriesID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.similarItems(itemID: itemID, userID: userID, limit: limit),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: query),
            responseType: JellyfinItemsResponse.self
        )
    }

    func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? {
        try await findByProviderIDs(
            userID: userID,
            tmdbID: tmdbID,
            tvdbID: nil,
            imdbID: nil,
            includeItemTypes: [.movie, .series],
            searchTerm: searchTerm
        )
    }

    func findByProviderIDs(
        userID: String,
        tmdbID: Int?,
        tvdbID: Int?,
        imdbID: String?,
        includeItemTypes: [ItemType],
        searchTerm: String?
    ) async throws -> JellyfinItem? {
        var values: [String] = []
        if let tmdbID { values.append("tmdb.\(tmdbID)") }
        if let tvdbID { values.append("tvdb.\(tvdbID)") }
        if let imdbID, !imdbID.isEmpty { values.append("imdb.\(imdbID)") }
        guard !values.isEmpty else { return nil }

        // Jellyfin has NO server-side provider-id filter (AnyProviderIdEquals is an Emby parameter; Jellyfin drops unknown query items silently). A narrow title search is the only way to get the right item into the candidate set, and every candidate is verified against the ids below, so a miss returns nil instead of an arbitrary item.
        let query = ItemQuery(
            includeItemTypes: includeItemTypes,
            limit: searchTerm == nil ? nil : candidateLimit,
            searchTerm: searchTerm,
            fields: "ProviderIds"
        )
        let candidates = try await getCollectionItems(userID: userID, query: query).items
        for value in values {
            if let hit = candidates.first(where: { $0.carriesProviderID(value) }) {
                return hit
            }
        }
        return nil
    }

    func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.persons(userID: userID, searchTerm: name, limit: limit),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    /// Title search only narrows, it never decides: the provider-id check does. Wide enough to survive
    /// a library with several same-named entries, small enough to stay one cheap round-trip. Callers
    /// that pass no title get the full typed list instead, correct but a much heavier response.
    private var candidateLimit: Int { 25 }

    func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {
        let endpoint: JellyfinEndpoint = isFavorite
            ? .markFavorite(userID: userID, itemID: itemID)
            : .unmarkFavorite(userID: userID, itemID: itemID)
        try await client.request(endpoint: endpoint)
    }

    func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {
        let endpoint: JellyfinEndpoint = isPlayed
            ? .markPlayed(userID: userID, itemID: itemID)
            : .unmarkPlayed(userID: userID, itemID: itemID)
        try await client.request(endpoint: endpoint)
    }

    func deleteItem(itemID: String) async throws {
        try await client.request(endpoint: JellyfinEndpoint.deleteItem(itemID: itemID))
    }
}

extension JellyfinItemService: UserItemDataServing {
    func userData(itemID: String, userID: String) async throws -> UserItemData {
        try await client.request(endpoint: JellyfinEndpoint.userItemData(itemID: itemID, userID: userID), responseType: UserItemData.self)
    }

    func updateUserData(itemID: String, userID: String, positionTicks: Int64, played: Bool, lastPlayed: Date) async throws {
        let payload = try JSONValue(jsonObject: [
            "PlaybackPositionTicks": positionTicks,
            "Played": played,
            "LastPlayedDate": JellyfinDate.format(lastPlayed),
        ])
        try await client.request(endpoint: JellyfinEndpoint.updateUserItemData(itemID: itemID, userID: userID, payload: payload))
    }
}

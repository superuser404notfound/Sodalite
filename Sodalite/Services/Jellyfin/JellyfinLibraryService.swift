import Foundation

protocol JellyfinLibraryServiceProtocol: Sendable {
    func getLibraries(userID: String) async throws -> [JellyfinLibrary]
    func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse
    func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse
    func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse
    func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem]
    func getGenres(userID: String) async throws -> [NamedItem]
    func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem]
    /// What a library grid's filter menu lists for that grid's own library (Sodalite#252).
    func getFilterFacets(userID: String, scope: FacetScope) async throws -> ServerFacets
}

extension JellyfinLibraryServiceProtocol {
    /// Test doubles that never exercise the Upcoming row answer with nothing.
    func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem] { [] }

    /// Test doubles that never open a filter menu list nothing, so the menu shows its fixed groups.
    func getFilterFacets(userID: String, scope: FacetScope) async throws -> ServerFacets { ServerFacets() }

    /// Ordinary Next Up (non-Home callers); rewatching is a Home-row-only opt-in, defaulted off here.
    func getNextUp(userID: String, seriesID: String?, limit: Int) async throws -> JellyfinItemsResponse {
        try await getNextUp(userID: userID, seriesID: seriesID, limit: limit, rewatching: false)
    }
}

final class JellyfinLibraryService: JellyfinLibraryServiceProtocol {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.userViews(userID: userID),
            responseType: JellyfinItemsResponse.self
        )
        return response.items.map { item in
            JellyfinLibrary(
                id: item.id,
                name: item.name,
                collectionType: item.collectionType,
                imageTags: item.imageTags
            )
        }
    }

    func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
        guard let studioNames = query.studioNames, !studioNames.isEmpty else {
            return try await client.request(
                endpoint: JellyfinEndpoint.items(userID: userID, query: query),
                responseType: JellyfinItemsResponse.self
            )
        }
        var checked = query
        checked.fields = StudioFilterCheck.fields(query.fields)
        let response = try await client.request(
            endpoint: JellyfinEndpoint.items(userID: userID, query: checked),
            responseType: JellyfinItemsResponse.self
        )
        let result = StudioFilterCheck.filter(response, studioNames: studioNames)
        if result.dropped > 0 {
            LogTap.shared.note("[jellyfin] Studios filter not applied by the server, dropped \(result.dropped) of \(response.items.count) items")
        }
        return result.response
    }

    func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.resumeItems(userID: userID, mediaType: mediaType, limit: limit),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
        try await client.request(
            endpoint: JellyfinEndpoint.nextUp(userID: userID, seriesID: seriesID, limit: limit, rewatching: rewatching),
            responseType: JellyfinItemsResponse.self
        )
    }

    func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
        let response: LossyJellyfinItems = try await client.request(
            endpoint: JellyfinEndpoint.latestMedia(
                userID: userID,
                parentID: parentID,
                includeItemTypes: includeItemTypes,
                limit: limit
            ),
            responseType: LossyJellyfinItems.self
        )
        return response.elements
    }

    func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem] {
        try await client.request(
            endpoint: JellyfinEndpoint.upcoming(userID: userID, limit: limit),
            responseType: JellyfinItemsResponse.self
        ).items
    }

    /// Three calls, the way Jellyfin web fills its menu: genres, ratings, tags and years from the
    /// legacy `/Items/Filters`, genre ids and the languages from `/Items/Filters2`, studios from
    /// `/Studios`. Only the first one has to answer; without `Filters2` the language groups stay
    /// hidden and genres go out by name.
    func getFilterFacets(userID: String, scope: FacetScope) async throws -> ServerFacets {
        async let legacy = client.request(
            endpoint: JellyfinEndpoint.itemFilters(userID: userID, scope: scope),
            responseType: LegacyFiltersResponse.self
        )
        async let modern = try? client.request(
            endpoint: JellyfinEndpoint.itemFilters2(userID: userID, scope: scope),
            responseType: QueryFilters2Response.self
        )
        async let studios = try? client.request(
            endpoint: JellyfinEndpoint.studios(userID: userID, scope: scope),
            responseType: NamedItemsResponse.self
        )
        let base = try await legacy
        let extra = await modern
        let studioItems = await studios?.items ?? []
        return ServerFacets(
            // Filters2 takes `Recursive` and the legacy call does not, so on a folder grid its list
            // is the true one, and every genre on it has an id to send.
            genres: extra?.genres.map { $0.map(\.name) } ?? base.genres ?? [],
            genreIDs: Dictionary((extra?.genres ?? []).map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first }),
            officialRatings: base.officialRatings ?? [],
            tags: base.tags ?? [],
            years: (base.years ?? []).sorted(by: >),
            studios: studioItems.map(\.name),
            studioIDs: Dictionary(studioItems.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first }),
            audioLanguages: (extra?.audioLanguages ?? []).map { LanguageFacet(name: $0.name, value: $0.value) },
            subtitleLanguages: (extra?.subtitleLanguages ?? []).map { LanguageFacet(name: $0.name, value: $0.value) }
        )
    }

    func getGenres(userID: String) async throws -> [NamedItem] {
        let response: NamedItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.genres(userID: userID),
            responseType: NamedItemsResponse.self
        )
        return response.items
    }
}

/// `/Items/Filters`: plain name lists.
nonisolated struct LegacyFiltersResponse: Decodable, Sendable {
    let genres: [String]?
    let tags: [String]?
    let officialRatings: [String]?
    let years: [Int]?

    enum CodingKeys: String, CodingKey {
        case genres = "Genres"
        case tags = "Tags"
        case officialRatings = "OfficialRatings"
        case years = "Years"
    }
}

/// `/Items/Filters2`: genres with ids, and the languages as name and code.
nonisolated struct QueryFilters2Response: Decodable, Sendable {
    struct Language: Decodable, Sendable {
        let name: String
        let value: String

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case value = "Value"
        }
    }

    let genres: [NamedItem]?
    let audioLanguages: [Language]?
    let subtitleLanguages: [Language]?

    enum CodingKeys: String, CodingKey {
        case genres = "Genres"
        case audioLanguages = "AudioLanguages"
        case subtitleLanguages = "SubtitleLanguages"
    }
}

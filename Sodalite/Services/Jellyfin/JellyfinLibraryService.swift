import Foundation

protocol JellyfinLibraryServiceProtocol: Sendable {
    func getLibraries(userID: String) async throws -> [JellyfinLibrary]
    func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse
    func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse
    func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse
    func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem]
    func getGenres(userID: String) async throws -> [NamedItem]
    func getStudios(userID: String) async throws -> [NamedItem]
    func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem]
}

extension JellyfinLibraryServiceProtocol {
    /// Test doubles that never exercise the Upcoming row answer with nothing.
    func getUpcoming(userID: String, limit: Int) async throws -> [JellyfinItem] { [] }

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

    func getGenres(userID: String) async throws -> [NamedItem] {
        let response: NamedItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.genres(userID: userID),
            responseType: NamedItemsResponse.self
        )
        return response.items
    }

    func getStudios(userID: String) async throws -> [NamedItem] {
        let response: NamedItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.studios(userID: userID),
            responseType: NamedItemsResponse.self
        )
        return response.items
    }
}

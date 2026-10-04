import Testing
import Foundation
@testable import Sodalite

/// Removing a title from Radarr/Sonarr leaves its request standing, and Jellyseerr's availability
/// sync only ever revisits *available* titles, so that leftover request reports a pipeline state
/// ("processing") for a title that no longer exists, permanently. Deleting it is part of the delete.
@MainActor
struct MediaDeletionRequestCleanupTests {
    private final class ItemsSpy: JellyfinItemServiceProtocol, @unchecked Sendable {
        var deleted: [String] = []
        var throwOnDelete = false
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw Boom() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw Boom() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw Boom() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw Boom() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Boom() }
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {
            if throwOnDelete { throw Boom() }
            deleted.append(itemID)
        }
    }

    private final class MediaSpy: SeerrMediaServiceProtocol, @unchecked Sendable {
        var requests: [SeerrRequest] = []
        var removedFromArr: [Int] = []
        func movieDetail(tmdbID: Int) async throws -> SeerrMovieDetail { throw Boom() }
        func tvDetail(tmdbID: Int) async throws -> SeerrTVDetail {
            try decodeTVDetail(requests: requests)
        }
        func tvSeasonDetail(tmdbID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetail { throw Boom() }
        func collection(collectionID: Int) async throws -> SeerrCollection { throw Boom() }
        func recommendations(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] { [] }
        func similar(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] { [] }
        func ratings(mediaType: SeerrMediaType, tmdbID: Int) async throws -> SeerrRTRating { throw Boom() }
        func personDetail(tmdbID: Int) async throws -> SeerrPersonDetail { throw Boom() }
        func personCredits(tmdbID: Int) async throws -> SeerrPersonCredits { throw Boom() }
        func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool { removedFromArr.append(tmdbID); return true }
        func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool { removedFromArr.append(tmdbID); return true }
    }

    private final class RequestsSpy: SeerrRequestServiceProtocol, @unchecked Sendable {
        var deleted: [Int] = []
        var throwOnDelete = false
        func createRequest(mediaType: SeerrMediaType, tmdbID: Int, seasons: [Int]?, serverID: Int?, profileID: Int?, rootFolder: String?, languageProfileID: Int?, tags: [Int]?) async throws -> SeerrRequest { throw Boom() }
        func myRequests(userID: Int, take: Int, skip: Int) async throws -> SeerrRequestsResult { throw Boom() }
        func allRequests(filter: SeerrRequestFilter, take: Int, skip: Int) async throws -> SeerrRequestsResult { throw Boom() }
        func approveRequest(requestID: Int) async throws -> SeerrRequest { throw Boom() }
        func declineRequest(requestID: Int) async throws -> SeerrRequest { throw Boom() }
        func deleteRequest(requestID: Int) async throws {
            if throwOnDelete { throw Boom() }
            deleted.append(requestID)
        }
        func updateRequest(requestID: Int, body: SeerrRequestUpdateBody) async throws -> SeerrRequest { throw Boom() }
    }

    private struct Boom: Error {}

    private func makeService(
        items: ItemsSpy, media: MediaSpy, requests: RequestsSpy, signedIn: Bool = true
    ) -> MediaDeletionService {
        MediaDeletionService(
            jellyfinItems: items,
            seerrMedia: media,
            seerrRequests: requests,
            isSeerrAuthenticated: { signedIn }
        )
    }

    @Test func cascadingDeleteClearsTheOpenRequest() async throws {
        let items = ItemsSpy(), media = MediaSpy(), requests = RequestsSpy()
        media.requests = [try makeRequest(id: 7, status: 2)]
        try await makeService(items: items, media: media, requests: requests)
            .deleteSeries(itemID: "jf-1", tmdbID: 42, cascadeToArrStack: true)
        #expect(items.deleted == ["jf-1"])
        #expect(media.removedFromArr == [42])
        #expect(requests.deleted == [7])
    }

    /// Declined, failed and completed requests are history; touching them would rewrite the user's record.
    @Test func closedRequestsAreLeftAlone() async throws {
        let items = ItemsSpy(), media = MediaSpy(), requests = RequestsSpy()
        media.requests = [
            try makeRequest(id: 1, status: 3),
            try makeRequest(id: 2, status: 4),
            try makeRequest(id: 3, status: 5),
            try makeRequest(id: 4, status: 1),
        ]
        try await makeService(items: items, media: media, requests: requests)
            .deleteSeries(itemID: "jf-1", tmdbID: 42, cascadeToArrStack: true)
        #expect(requests.deleted == [4])
    }

    /// Without the cascade the user asked for a Jellyfin-only delete; the request is none of our business.
    @Test func nonCascadingDeleteTouchesNoRequest() async throws {
        let items = ItemsSpy(), media = MediaSpy(), requests = RequestsSpy()
        media.requests = [try makeRequest(id: 7, status: 2)]
        try await makeService(items: items, media: media, requests: requests)
            .deleteSeries(itemID: "jf-1", tmdbID: 42, cascadeToArrStack: false)
        #expect(requests.deleted.isEmpty)
        #expect(media.removedFromArr.isEmpty)
    }

    /// The deletion already succeeded. A request the user may not delete (Jellyseerr answers 403) must not turn it into a failure.
    @Test func requestDeleteFailureDoesNotFailTheDeletion() async throws {
        let items = ItemsSpy(), media = MediaSpy(), requests = RequestsSpy()
        media.requests = [try makeRequest(id: 7, status: 2)]
        requests.throwOnDelete = true
        try await makeService(items: items, media: media, requests: requests)
            .deleteSeries(itemID: "jf-1", tmdbID: 42, cascadeToArrStack: true)
        #expect(items.deleted == ["jf-1"])
    }

    @Test func movieDeleteAlsoClearsItsRequest() async throws {
        let items = ItemsSpy(), media = MediaSpy(), requests = RequestsSpy()
        media.requests = [try makeRequest(id: 9, status: 1)]
        // movieDetail throws in the spy, so this asserts the cascade survives an unreadable detail.
        try await makeService(items: items, media: media, requests: requests)
            .deleteMovie(itemID: "jf-2", tmdbID: 11, cascadeToArrStack: true)
        #expect(items.deleted == ["jf-2"])
        #expect(media.removedFromArr == [11])
    }
}

/// Status ints are the wire values on the request axis (1 pending approval, 2 approved, 3 declined, 4 failed, 5 completed).
private func makeRequest(id: Int, status: Int) throws -> SeerrRequest {
    let json = "{\"id\": \(id), \"status\": \(status), \"type\": \"tv\"}"
    return try JSONDecoder().decode(SeerrRequest.self, from: Data(json.utf8))
}

private func decodeTVDetail(requests: [SeerrRequest]) throws -> SeerrTVDetail {
    let encoded = try JSONEncoder().encode(requests)
    let requestsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
    let json = """
    {"id": 42, "name": "Show", "mediaInfo": {"id": 1, "tmdbId": 42, "status": 3, "requests": \(requestsJSON)}}
    """
    return try JSONDecoder().decode(SeerrTVDetail.self, from: Data(json.utf8))
}

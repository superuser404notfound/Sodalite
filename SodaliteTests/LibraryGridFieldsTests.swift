import Testing
import Foundation
@testable import Sodalite

/// Sodalite#68. `ItemQuery.fields` used to be optional with a `fields ?? defaultFields` fallback, so
/// every caller that did not think about it asked the server for the detail-screen field set. Four
/// grid queries did exactly that, pulling cast lists, media streams, chapters and trickplay metadata
/// for items rendered as a poster with a title under it. The fix is the missing default: `fields` is
/// a required initializer parameter, so a new list query cannot silently inherit the heavy set.
struct ItemQueryFieldSetTests {
    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    /// No fallback left: what the caller passes is what goes on the wire.
    @Test func queryEmitsExactlyTheFieldSetItWasGiven() {
        let query = ItemQuery(includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields)
        #expect(value(query.toQueryItems(), "Fields") == JellyfinEndpoint.homeRowFields)
    }

    /// The counting path (`WatchStatsViewModel`) wants no per-item payload at all. An empty set must
    /// still emit the parameter, so the server cannot fall back to a default of its own.
    @Test func emptyFieldSetStillEmitsTheParameter() {
        let items = ItemQuery(includeItemTypes: [.movie], limit: 0, fields: "").toQueryItems()
        #expect(value(items, "Fields") == "")
    }

    /// The point of the card set: none of the per-item arrays a grid cell never reads.
    @Test func cardFieldSetCarriesNoDetailOnlyField() {
        let card = Set(JellyfinEndpoint.homeRowFields.split(separator: ",").map(String.init))
        let detailOnly = ["People", "MediaStreams", "MediaSources", "Chapters", "Trickplay",
                          "LocalTrailerCount", "RemoteTrailers", "Studios", "Overview"]
        for field in detailOnly {
            #expect(!card.contains(field), "homeRowFields must not carry \(field)")
        }
    }

    /// The other half of the contract: whatever is trimmed elsewhere, the set handed to the player
    /// keeps what `PlayerViewModel` and `PlayerHostController` read off the item itself.
    @Test func detailFieldSetKeepsWhatThePlayerReadsOffTheItem() {
        let detail = Set(JellyfinEndpoint.detailFields.split(separator: ",").map(String.init))
        for field in ["Chapters", "Trickplay", "MediaStreams", "MediaSources"] {
            #expect(detail.contains(field), "detailFields must carry \(field)")
        }
    }
}

/// The one place slimming a grid query could have caused a silent regression: shuffle builds its
/// play queue from the grid's own query, and those items reach `PlayerViewModel` unchanged, on
/// auto-advance too. A slim set would have dropped chapter markers and server-side trickplay
/// scrubbing without any visible failure (trickplay falls back to local frame extraction).
@MainActor
struct ShuffleQueueFieldsTests {
    /// JellyfinItemsResponse is decode-only (no memberwise init); build the empty one from JSON.
    private static func emptyResponse() throws -> JellyfinItemsResponse {
        try JSONDecoder().decode(
            JellyfinItemsResponse.self,
            from: Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8)
        )
    }

    @MainActor
    private final class QueryRecorder: JellyfinLibraryServiceProtocol {
        private(set) var lastQuery: ItemQuery?

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            lastQuery = query
            return try ShuffleQueueFieldsTests.emptyResponse()
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            try ShuffleQueueFieldsTests.emptyResponse()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            try ShuffleQueueFieldsTests.emptyResponse()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    @Test func shuffleOverridesASlimGridFieldSet() async {
        let recorder = QueryRecorder()
        let gridQuery = ItemQuery(
            parentID: "lib1",
            includeItemTypes: [.movie],
            limit: 200,
            fields: JellyfinEndpoint.homeRowFields
        )

        _ = await VideoShuffleQueue.build(
            parentID: "lib1",
            baseQuery: gridQuery,
            itemTypes: [.movie],
            service: recorder,
            userID: "user1"
        )

        #expect(recorder.lastQuery?.fields == JellyfinEndpoint.detailFields)
    }

    /// Shuffle from a series detail passes no base query at all; that path must land on the same set.
    @Test func shuffleWithoutABaseQueryStillAsksForThePlaybackFields() async {
        let recorder = QueryRecorder()

        _ = await VideoShuffleQueue.build(
            parentID: "series1",
            itemTypes: [.episode],
            service: recorder,
            userID: "user1"
        )

        #expect(recorder.lastQuery?.fields == JellyfinEndpoint.detailFields)
    }
}

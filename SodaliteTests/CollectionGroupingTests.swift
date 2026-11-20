import Testing
import Foundation
@testable import Sodalite

/// Issue #44: Jellyfin's server-wide "Group movies into collections" only takes effect when the
/// client leaves `CollapseBoxSetItems` out of the query. Sodalite used to hard-code `false` on every
/// query, so the option was unreachable. These tests pin the three-state contract (server default /
/// always / never) end to end: query emission, preference storage, cache keying, shuffle safety.
struct CollectionGroupingQueryTests {
    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    /// Default stays `false`: every existing call site (home rows, search, detail) must keep sending
    /// the flat list, else a freshly added movie hides behind a collection tile.
    @Test func defaultQuerySuppressesCollapsing() {
        let items = ItemQuery(includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields).toQueryItems()
        #expect(value(items, "CollapseBoxSetItems") == "false")
    }

    /// nil is the whole point: the param must be absent so the server applies its own
    /// EnableGroupingMoviesIntoCollections config. An explicit `false` would override it.
    @Test func serverDefaultOmitsTheParameter() {
        var query = ItemQuery(includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields)
        query.collapseBoxSetItems = nil
        let items = query.toQueryItems()
        #expect(!items.contains { $0.name == "CollapseBoxSetItems" })
    }

    @Test func alwaysSendsTrue() {
        var query = ItemQuery(includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields)
        query.collapseBoxSetItems = true
        #expect(value(query.toQueryItems(), "CollapseBoxSetItems") == "true")
    }

    /// The rest of the query must be untouched by the new field.
    @Test func recursiveAndFieldsSurviveEveryMode() {
        for mode: Bool? in [nil, true, false] {
            var query = ItemQuery(parentID: "lib1", includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields)
            query.collapseBoxSetItems = mode
            let items = query.toQueryItems()
            #expect(value(items, "Recursive") == "true")
            #expect(value(items, "ParentId") == "lib1")
            #expect(items.contains { $0.name == "Fields" })
        }
    }
}

struct CollectionGroupingModeTests {
    /// system -> nil (server decides), always -> true, never -> false.
    @Test func mapsToQueryValue() {
        #expect(CollectionGrouping.system.queryValue == nil)
        #expect(CollectionGrouping.always.queryValue == true)
        #expect(CollectionGrouping.never.queryValue == false)
    }

    /// Raw values are the storage and cloud-sync contract; renaming one silently resets every
    /// synced device to the default.
    @Test func rawValuesAreStable() {
        #expect(CollectionGrouping.system.rawValue == "system")
        #expect(CollectionGrouping.always.rawValue == "always")
        #expect(CollectionGrouping.never.rawValue == "never")
        #expect(CollectionGrouping.allCases.count == 3)
    }

    @Test func unknownRawValueFallsBackToSystem() {
        #expect(CollectionGrouping(storedValue: "bogus") == .system)
        #expect(CollectionGrouping(storedValue: nil) == .system)
        #expect(CollectionGrouping(storedValue: "always") == .always)
    }
}

@MainActor
struct CollectionGroupingStorageTests {
    /// Fresh install follows the server, matching what jellyfin-web does for the same library.
    @Test func defaultsToSystem() {
        let serverID = "grouping-default-\(UUID().uuidString)"
        #expect(HomeRowConfig.collectionGrouping(scope: serverID) == .system)
    }

    /// Per server, like the Jellyfin option it mirrors: one server grouping must not flip another.
    @Test func storesPerServer() {
        let serverA = "grouping-a-\(UUID().uuidString)"
        let serverB = "grouping-b-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "libraryCollectionGrouping.\(serverA)")
            UserDefaults.standard.removeObject(forKey: "libraryCollectionGrouping.\(serverB)")
        }

        HomeRowConfig.setCollectionGrouping(.never, scope: serverA)
        HomeRowConfig.setCollectionGrouping(.always, scope: serverB)

        #expect(HomeRowConfig.collectionGrouping(scope: serverA) == .never)
        #expect(HomeRowConfig.collectionGrouping(scope: serverB) == .always)
    }
}

struct CollectionGroupingCacheKeyTests {
    /// FilteredGridView hydrates from FilterCache in init. Sharing one key across modes would paint
    /// the previous shape (flat list or collection tiles) for a frame after the setting flips.
    @Test func keyDiffersPerMode() {
        let keys = CollectionGrouping.allCases.map {
            FilterCacheKey.Home.library(id: "lib1", grouping: $0)
        }
        #expect(Set(keys).count == CollectionGrouping.allCases.count)
    }

    @Test func keyDiffersPerLibrary() {
        let a = FilterCacheKey.Home.library(id: "lib1", grouping: .system)
        let b = FilterCacheKey.Home.library(id: "lib2", grouping: .system)
        #expect(a != b)
    }
}

struct CollectionGroupingSyncTests {
    /// The field is optional so payloads written by older builds still decode; a non-optional
    /// addition would fail the whole ServerSyncPayload and drop the server from sync.
    @Test func decodesPayloadWrittenBeforeTheFieldExisted() throws {
        let legacy = Data(#"{"mergeCWNextUp":true,"rewatchNextUp":false}"#.utf8)
        let decoded = try JSONDecoder().decode(HomeRowsSyncState.self, from: legacy)
        #expect(decoded.collectionGrouping == nil)
        #expect(CollectionGrouping(storedValue: decoded.collectionGrouping) == .system)
    }

    @Test func roundTripsTheGroupingMode() throws {
        let state = HomeRowsSyncState(
            configsJSON: nil,
            mergeCWNextUp: false,
            rewatchNextUp: false,
            collectionGrouping: CollectionGrouping.always.rawValue
        )
        let decoded = try JSONDecoder().decode(
            HomeRowsSyncState.self, from: try JSONEncoder().encode(state)
        )
        #expect(decoded == state)
    }
}

/// Shuffle inherits the library grid's query. A collapsed BoxSet in the play queue is unplayable,
/// so the shuffle build must pin the flat list regardless of the grouping preference.
@MainActor
struct CollectionGroupingShuffleTests {
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
            return try CollectionGroupingShuffleTests.emptyResponse()
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            try CollectionGroupingShuffleTests.emptyResponse()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            try CollectionGroupingShuffleTests.emptyResponse()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    @Test func shuffleNeverCollapses() async {
        let recorder = QueryRecorder()
        var baseQuery = ItemQuery(parentID: "lib1", includeItemTypes: [.movie], fields: JellyfinEndpoint.homeRowFields)
        baseQuery.collapseBoxSetItems = nil

        _ = await VideoShuffleQueue.build(
            parentID: "lib1",
            baseQuery: baseQuery,
            itemTypes: [.movie],
            service: recorder,
            userID: "user1"
        )

        #expect(recorder.lastQuery?.collapseBoxSetItems == false)
    }
}

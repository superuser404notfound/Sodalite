import Testing
import Foundation
@testable import Sodalite

/// Sodalite#79, the cheap half: resolution rides along on every card query because `Width` and
/// `Height` are two ints off the BaseItem row, no MediaSourceManager involved. The field set stays
/// the same whether the setting is on or off, because grid and precompute write the same
/// `FilterCache` keys and two writers of one key must not carry different field sets (Sodalite#68).
struct PosterBadgeFieldSetTests {

    @Test("the card field set asks for the item width, the pill's only free input")
    func cardFieldSetCarriesWidth() {
        let fields = Set(JellyfinEndpoint.homeRowFields.split(separator: ",").map(String.init))
        #expect(fields.contains("Width"))
        #expect(fields.contains("Height"))
    }

    @Test("the card field set still refuses the expensive stream fields")
    func cardFieldSetStillHasNoStreams() {
        let fields = Set(JellyfinEndpoint.homeRowFields.split(separator: ",").map(String.init))
        #expect(!fields.contains("MediaStreams"))
        #expect(!fields.contains("MediaSources"))
    }

    @Test("an item decodes the width the server sends")
    func itemDecodesWidth() throws {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"m1","Name":"A","Type":"Movie","Width":3840,"Height":2160}"#.utf8))
        #expect(item.width == 3840)
        #expect(item.height == 2160)
    }
}

/// The expensive half: dynamic range and spatial audio only exist in MediaStreams, which cost a
/// `GetStaticMediaSources` call per item on the server. They are fetched after the first frame, in
/// batches, and never twice for the same id.
@MainActor
struct PosterBadgeStoreTests {

    // MARK: - Fixtures

    private static func item(id: String, type: String, width: Int? = nil) throws -> JellyfinItem {
        var fields = [#""Id":"\#(id)""#, #""Name":"\#(id)""#, #""Type":"\#(type)""#]
        if let width { fields.append(#""Width":\#(width)"#) }
        return try JSONDecoder().decode(JellyfinItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    /// An /Items envelope whose items carry a video stream and, optionally, a spatial audio track.
    private static func response(ids: [String], range: String? = "HDR10", atmos: Bool = false) throws -> JellyfinItemsResponse {
        let items = ids.map { id -> String in
            var streams = [#"{"Index":0,"Type":"Video","Width":3840,"VideoRangeType":"\#(range ?? "SDR")"}"#]
            if atmos {
                streams.append(#"{"Index":1,"Type":"Audio","Codec":"eac3","Profile":"Dolby Digital+ with Dolby Atmos"}"#)
            }
            return #"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","MediaStreams":[\#(streams.joined(separator: ","))]}"#
        }
        return try JSONDecoder().decode(
            JellyfinItemsResponse.self,
            from: Data(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(ids.count)}"#.utf8))
    }

    private static func emptyResponse() throws -> JellyfinItemsResponse {
        try JSONDecoder().decode(JellyfinItemsResponse.self,
                                 from: Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8))
    }

    @MainActor
    private final class LibraryFake: JellyfinLibraryServiceProtocol {
        private(set) var queries: [ItemQuery] = []
        var respond: (@MainActor (ItemQuery) throws -> JellyfinItemsResponse)?

        private(set) var maxConcurrent = 0
        private var concurrent = 0

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            queries.append(query)
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            await Task.yield()  // hands the actor over, so an unthrottled sibling would overlap here
            concurrent -= 1
            if let respond { return try respond(query) }
            return try PosterBadgeStoreTests.emptyResponse()
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            try PosterBadgeStoreTests.emptyResponse()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            try PosterBadgeStoreTests.emptyResponse()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func store(_ library: LibraryFake, enabled: Bool = true) -> PosterBadgeStore {
        PosterBadgeStore(route: { _ in (library, "u1") }, isEnabled: { enabled })
    }

    // MARK: - The free half

    @Test("a poster paints its resolution before any enrichment has run")
    func resolutionWithoutEnrichment() throws {
        let store = store(LibraryFake())
        #expect(store.badges(for: try Self.item(id: "m1", type: "Movie", width: 3840)).resolution == .uhd)
    }

    @Test("a series poster says nothing until its sample lands")
    func seriesSaysNothingBeforeEnrichment() throws {
        let store = store(LibraryFake())
        #expect(store.badges(for: try Self.item(id: "s1", type: "Series")).isEmpty)
    }

    // MARK: - Batching

    @Test("a row of movies costs one request, not one per card")
    func moviesAreFetchedInOneBatch() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.response(ids: ["m1", "m2", "m3"]) }
        let store = store(library)

        await store.enrich(userID: "u1", [try Self.item(id: "m1", type: "Movie"),
                            try Self.item(id: "m2", type: "Movie"),
                            try Self.item(id: "m3", type: "Movie")])

        #expect(library.queries.count == 1)
        #expect(library.queries.first?.ids == ["m1", "m2", "m3"])
        #expect(library.queries.first?.fields == "MediaStreams")
    }

    @Test("a grid full of movies is split so no single URL carries every id")
    func batchesAreCapped() async throws {
        let library = LibraryFake()
        library.respond = { query in try Self.response(ids: query.ids ?? []) }
        let store = store(library)
        let items = try (1...90).map { try Self.item(id: "m\($0)", type: "Movie") }

        await store.enrich(userID: "u1", items)

        #expect(library.queries.count == 3)
        #expect(library.queries.allSatisfy { ($0.ids?.count ?? 0) <= 40 })
    }

    @Test("what the enrichment found is added to what the width already said")
    func enrichmentAddsToTheResolution() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.response(ids: ["m1"], range: "HDR10", atmos: true) }
        let store = store(library)
        let movie = try Self.item(id: "m1", type: "Movie", width: 1920)

        await store.enrich(userID: "u1", [movie])

        let badges = store.badges(for: movie)
        #expect(badges.dynamicRange == .hdr10)
        #expect(badges.audio == .atmos)
        #expect(badges.resolution == .uhd, "the stream's own width corrects a stale item width")
    }

    @Test("an id already enriched is not asked for a second time")
    func enrichedIdsAreNotRefetched() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.response(ids: ["m1"]) }
        let store = store(library)
        let movie = try Self.item(id: "m1", type: "Movie")

        await store.enrich(userID: "u1", [movie])
        await store.enrich(userID: "u1", [movie])

        #expect(library.queries.count == 1)
    }

    @Test("an item the server answered nothing about is not asked again either")
    func silentItemsAreNotRetried() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.emptyResponse() }
        let store = store(library)
        let movie = try Self.item(id: "m1", type: "Movie")

        await store.enrich(userID: "u1", [movie])
        await store.enrich(userID: "u1", [movie])

        #expect(library.queries.count == 1)
    }

    @Test("an item that already carries its streams is never asked about")
    func itemsThatCarryTheirStreamsAreNotFetched() async throws {
        let library = LibraryFake()
        let store = store(library)
        let detailed = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"m1","Name":"A","Type":"Movie","MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"VideoRangeType":"HDR10"}]}"#.utf8))

        await store.enrich(userID: "u1", [detailed])

        #expect(library.queries.isEmpty)
        #expect(store.badges(for: detailed).dynamicRange == .hdr10)
    }

    @Test("a request that failed is retried on the next pass, a hole is not a negative result")
    func failedRequestsAreRetried() async throws {
        struct Boom: Error {}
        let library = LibraryFake()
        library.respond = { _ in throw Boom() }
        let store = store(library)
        let movie = try Self.item(id: "m1", type: "Movie")

        await store.enrich(userID: "u1", [movie])
        await store.enrich(userID: "u1", [movie])

        #expect(library.queries.count == 2)
    }

    // MARK: - Series sampling

    @Test("a series is sampled from its newest episode, one request, limit one")
    func seriesSampledFromNewestEpisode() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.response(ids: ["e9"], range: "HDR10") }
        let store = store(library)
        let series = try Self.item(id: "s1", type: "Series")

        await store.enrich(userID: "u1", [series])

        let query = try #require(library.queries.first)
        #expect(library.queries.count == 1)
        #expect(query.parentID == "s1")
        #expect(query.includeItemTypes == [.episode])
        #expect(query.limit == 1)
        #expect(query.sortBy == "DateCreated")
        #expect(query.sortOrder == "Descending")
        #expect(query.fields == "MediaStreams")
        #expect(store.badges(for: series).dynamicRange == .hdr10)
    }

    @Test("a series with no episodes is not sampled again on the next pass")
    func emptySeriesIsNotResampled() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.emptyResponse() }
        let store = store(library)
        let series = try Self.item(id: "s1", type: "Series")

        await store.enrich(userID: "u1", [series])
        await store.enrich(userID: "u1", [series])

        #expect(library.queries.count == 1)
    }

    @Test("series samples from two rows queue up instead of fanning out")
    func seriesSamplesAreSerialisedAcrossRows() async throws {
        let library = LibraryFake()
        library.respond = { _ in try Self.response(ids: ["e1"]) }
        let store = store(library)
        let rowA = [try Self.item(id: "s1", type: "Series"), try Self.item(id: "s2", type: "Series")]
        let rowB = [try Self.item(id: "s3", type: "Series"), try Self.item(id: "s4", type: "Series")]

        async let first: Void = store.enrich(userID: "u1", rowA)
        async let second: Void = store.enrich(userID: "u1", rowB)
        _ = await (first, second)

        #expect(library.queries.count == 4)
        #expect(library.maxConcurrent == 1)
    }

    // MARK: - The switch and the item types

    @Test("with the setting off not a single request flies")
    func disabledStoreIsSilent() async throws {
        let library = LibraryFake()
        let store = store(library, enabled: false)

        await store.enrich(userID: "u1", [try Self.item(id: "m1", type: "Movie"),
                            try Self.item(id: "s1", type: "Series")])

        #expect(library.queries.isEmpty)
    }

    @Test("item types that own no streams are never asked about")
    func typesWithoutStreamsAreSkipped() async throws {
        let library = LibraryFake()
        let store = store(library)

        await store.enrich(userID: "u1", [try Self.item(id: "b1", type: "BoxSet"),
                            try Self.item(id: "f1", type: "Folder"),
                            try Self.item(id: "a1", type: "MusicAlbum"),
                            try Self.item(id: "p1", type: "Playlist")])

        #expect(library.queries.isEmpty)
    }

    @Test("movies and episodes share one batch, series add their own sample")
    func mixedRowSplitsIntoBatchAndSamples() async throws {
        let library = LibraryFake()
        library.respond = { query in try Self.response(ids: query.ids ?? ["e1"]) }
        let store = store(library)

        await store.enrich(userID: "u1", [try Self.item(id: "m1", type: "Movie"),
                            try Self.item(id: "e1", type: "Episode"),
                            try Self.item(id: "s1", type: "Series")])

        #expect(library.queries.count == 2)
        #expect(library.queries.contains { $0.ids == ["m1", "e1"] })
        #expect(library.queries.contains { $0.parentID == "s1" })
    }
}

/// The switch itself (Sodalite#79): off until asked for, remembered across launches, and carried by
/// CloudSync like every other appearance setting (the parity suite pins that half).
@MainActor
struct PosterBadgeSettingTests {

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "posterBadges.\(name)")!
        defaults.removePersistentDomain(forName: "posterBadges.\(name)")
        return defaults
    }

    @Test("poster badges stay off until someone turns them on")
    func offByDefault() {
        let prefs = AppearancePreferences(store: scratchDefaults("default"))
        #expect(prefs.showPosterBadges == false)
    }

    @Test("the badge switch survives a relaunch")
    func survivesRelaunch() {
        let defaults = scratchDefaults("persist")
        AppearancePreferences(store: defaults).showPosterBadges = true
        #expect(AppearancePreferences(store: defaults).showPosterBadges)
    }
}

import Testing
import Foundation
@testable import Sodalite

/// Attaching the wrong person's library to a page is silent and looks plausible, so the matching
/// rules get their own tests (Sodalite#57).
@MainActor
struct PersonLibraryTests {
    private func person(_ id: String, _ name: String, tmdb: Int? = nil) throws -> JellyfinItem {
        let providers = tmdb.map { #","ProviderIds":{"Tmdb":"\#($0)"}"# } ?? ""
        return try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(name)","Type":"Person"\#(providers)}"#.utf8)
        )
    }

    // MARK: - matchPerson

    @Test func tmdbIDPicksTheRightPersonAmongSameNamedCandidates() throws {
        let candidates = [
            try person("a", "Chris Evans", tmdb: 9999),
            try person("b", "Chris Evans", tmdb: 16828),
        ]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "Chris Evans", tmdbID: 16828)?.id == "b")
    }

    /// The id proves identity; punctuation and spelling of the name do not.
    @Test func tmdbIDWinsOverADifferentlySpelledName() throws {
        let candidates = [try person("a", "Robert Downey, Jr.", tmdb: 3223)]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "Robert Downey Jr.", tmdbID: 3223)?.id == "a")
    }

    /// Someone else's id is a different person, not a weak match.
    @Test func candidateWithAForeignTmdbIDIsRejected() throws {
        let candidates = [try person("a", "Chris Evans", tmdb: 9999)]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "Chris Evans", tmdbID: 16828) == nil)
    }

    /// Libraries routinely carry cast with no provider ids at all; a single unambiguous name is
    /// the only case where that is safe.
    @Test func singleUnidentifiedNameMatchIsAccepted() throws {
        let candidates = [try person("a", "Mindy Kaling")]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "Mindy Kaling", tmdbID: 55638)?.id == "a")
    }

    @Test func twoUnidentifiedSameNamedPeopleAreRejected() throws {
        let candidates = [try person("a", "John Smith"), try person("b", "John Smith")]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "John Smith", tmdbID: 42) == nil)
    }

    @Test func nameComparisonIgnoresCaseAndDiacritics() throws {
        let candidates = [try person("a", "penelope cruz")]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "Penélope Cruz", tmdbID: 1289)?.id == "a")
    }

    @Test func unrelatedCandidatesAreRejected() throws {
        let candidates = [try person("a", "Someone Else", tmdb: 1)]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "Mindy Kaling", tmdbID: 55638) == nil)
    }

    @Test func emptyNameWithoutIDMatchesNothing() throws {
        let candidates = [try person("a", "Mindy Kaling")]
        #expect(PersonLibrary.matchPerson(in: candidates, name: "   ", tmdbID: nil) == nil)
    }

    // MARK: - resolvePersonID

    @Test func knownJellyfinIDSkipsTheNameSearch() async throws {
        let spy = ItemsSpy()
        let resolved = await PersonLibrary.resolvePersonID(
            itemService: spy, userID: "u", jellyfinPersonID: "person-7", name: "Mindy Kaling", tmdbID: 55638
        )
        #expect(resolved == "person-7")
        #expect(spy.personSearches.isEmpty)
    }

    @Test func seerrSourcedPageResolvesThroughTheNameSearch() async throws {
        let spy = ItemsSpy()
        spy.persons = [try person("p1", "Mindy Kaling", tmdb: 55638)]
        let resolved = await PersonLibrary.resolvePersonID(
            itemService: spy, userID: "u", jellyfinPersonID: nil, name: "Mindy Kaling", tmdbID: 55638
        )
        #expect(resolved == "p1")
        #expect(spy.personSearches == ["Mindy Kaling"])
    }

    @Test func failedPersonSearchResolvesToNothing() async throws {
        let spy = ItemsSpy()
        spy.throwOnPersonSearch = true
        let resolved = await PersonLibrary.resolvePersonID(
            itemService: spy, userID: "u", jellyfinPersonID: nil, name: "Mindy Kaling", tmdbID: 55638
        )
        #expect(resolved == nil)
    }

    // MARK: - load

    @Test func loadSplitsTheThreeTypesAndScopesEachQueryToThePerson() async throws {
        let spy = ItemsSpy()
        spy.itemsByType = [
            .movie: [try item("m1", type: "Movie")],
            .series: [try item("s1", type: "Series")],
            .episode: [try item("e1", type: "Episode"), try item("e2", type: "Episode")],
        ]

        let results = await PersonLibrary.load(itemService: spy, userID: "u", personID: "p1")

        #expect(results.movies.map(\.id) == ["m1"])
        #expect(results.series.map(\.id) == ["s1"])
        #expect(results.episodes.map(\.id) == ["e1", "e2"])
        #expect(!results.isEmpty)
        #expect(spy.queries.count == 3)
        #expect(spy.queries.allSatisfy { $0.personIDs == ["p1"] })
        #expect(spy.queries.allSatisfy { $0.limit == PersonLibrary.rowLimit })
    }

    /// One failing row must not take the other two with it.
    @Test func aFailingRowLeavesTheOthersStanding() async throws {
        let spy = ItemsSpy()
        spy.itemsByType = [.movie: [try item("m1", type: "Movie")]]
        spy.throwForTypes = [.episode]

        let results = await PersonLibrary.load(itemService: spy, userID: "u", personID: "p1")

        #expect(results.movies.map(\.id) == ["m1"])
        #expect(results.episodes.isEmpty)
    }

    @Test func emptyLibraryReportsEmpty() async throws {
        let results = await PersonLibrary.load(itemService: ItemsSpy(), userID: "u", personID: "p1")
        #expect(results.isEmpty)
    }

    // MARK: - Missing entries

    /// A server with "display missing episodes" on returns episodes it holds no file for. They
    /// cannot be opened or played, so a row headed "in Your Library" must not carry them.
    @Test func virtualEpisodesAreKeptOutOfTheRows() async throws {
        let spy = ItemsSpy()
        spy.itemsByType = [
            .episode: [
                try item("real", type: "Episode", locationType: "FileSystem"),
                try item("missing", type: "Episode", locationType: "Virtual"),
            ],
        ]

        let results = await PersonLibrary.load(itemService: spy, userID: "u", personID: "p1")

        #expect(results.episodes.map(\.id) == ["real"])
    }

    /// The row is gone rather than showing a title that isn't there, which is what the reporter saw.
    @Test func aRowOfNothingButMissingEpisodesDisappears() async throws {
        let spy = ItemsSpy()
        spy.itemsByType = [.episode: [try item("missing", type: "Episode", locationType: "Virtual")]]

        let results = await PersonLibrary.load(itemService: spy, userID: "u", personID: "p1")

        #expect(results.episodes.isEmpty)
        #expect(results.isEmpty)
    }

    /// Cheaper than filtering a full row away afterwards; the row limit gets spent on real titles.
    @Test func theEpisodeQueryAsksTheServerToDropMissingOnes() async throws {
        let spy = ItemsSpy()
        _ = await PersonLibrary.load(itemService: spy, userID: "u", personID: "p1")

        let episodeQuery = spy.queries.first { $0.includeItemTypes == [.episode] }
        #expect(episodeQuery?.isMissing == false)
        // IsMissing is an episode filter; sending it on the other two would be noise.
        #expect(spy.queries.filter { $0.includeItemTypes != [.episode] }.allSatisfy { $0.isMissing == nil })
    }

    @Test func locationTypeDecodesFromTheServerField() throws {
        #expect(try item("a", type: "Episode", locationType: "Virtual").isVirtual)
        #expect(try !item("b", type: "Episode", locationType: "FileSystem").isVirtual)
        #expect(try !item("c", type: "Episode").isVirtual)
    }

    private func item(_ id: String, type: String, locationType: String? = nil) throws -> JellyfinItem {
        let location = locationType.map { #","LocationType":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"\#(location)}"#.utf8)
        )
    }

    final class ItemsSpy: JellyfinItemServiceProtocol, @unchecked Sendable {
        var persons: [JellyfinItem] = []
        var throwOnPersonSearch = false
        var personSearches: [String] = []
        var itemsByType: [ItemType: [JellyfinItem]] = [:]
        var throwForTypes: Set<ItemType> = []
        var queries: [ItemQuery] = []
        var details: [String: JellyfinItem] = [:]

        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
            guard let item = details[itemID] else { throw Boom() }
            return item
        }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw Boom() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw Boom() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw Boom() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            queries.append(query)
            let type = query.includeItemTypes?.first
            if let type, throwForTypes.contains(type) { throw Boom() }
            let items = type.flatMap { itemsByType[$0] } ?? []
            return JellyfinItemsResponse(items: items, totalRecordCount: items.count)
        }
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] {
            personSearches.append(name)
            if throwOnPersonSearch { throw Boom() }
            return persons
        }
        func deleteItem(itemID: String) async throws {}

        private struct Boom: Error {}
    }
}

import Foundation
import Testing
@testable import Sodalite

/// Sodalite#240: a film on two combined servers offers both servers' versions on its page. The
/// lookup is the part that can go wrong quietly (a wrong film, a server that hangs the page, a copy
/// with nothing to play), so that is what these pin down.
@MainActor
struct ServerTwinsTests {
    private func movie(
        _ id: String, _ name: String, server: String, tmdb: String? = "603",
        original: String? = nil, sources: [String] = []
    ) throws -> JellyfinItem {
        var json: [String: Any] = ["Id": id, "Name": name, "Type": "Movie", "ServerId": server]
        if let tmdb { json["ProviderIds"] = ["Tmdb": tmdb] }
        if let original { json["OriginalTitle"] = original }
        if !sources.isEmpty {
            json["MediaSources"] = sources.map { ["Id": $0, "Container": "mkv"] }
        }
        return try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    final class Spy: JellyfinItemServiceProtocol, @unchecked Sendable {
        /// Search term to the item it finds; the provider-id check is the real service's job.
        var hits: [String: JellyfinItem] = [:]
        var details: [String: JellyfinItem] = [:]
        var stalls = false
        var searches: [String] = []

        func findByProviderIDs(userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?) async throws -> JellyfinItem? {
            searches.append(searchTerm ?? "")
            if stalls { try await Task.sleep(for: .seconds(30)) }
            return searchTerm.flatMap { hits[$0] }
        }
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem {
            guard let item = details[itemID] else { throw Boom() }
            return item
        }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw Boom() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw Boom() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw Boom() }
        func getPlaylistItems(playlistID: String, userID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse { throw Boom() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func setRating(userID: String, itemID: String, rating: Double?) async throws {}
        func clearPlaybackPosition(userID: String, itemID: String) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Boom() }
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {}

        private struct Boom: Error {}
    }

    private func source(_ server: String, _ spy: Spy) -> TwinSource {
        TwinSource(serverID: server, serverName: "Server \(server)", userID: "u-\(server)", itemService: spy)
    }

    @Test func theOtherServersCopyComesBackWithItsVersions() async throws {
        let page = try movie("m", "The Matrix", server: "a", sources: ["a1"])
        let spy = Spy()
        spy.hits["The Matrix"] = try movie("x", "The Matrix", server: "b")
        spy.details["x"] = try movie("x", "The Matrix", server: "b", sources: ["b1", "b2"])

        let twins = await ServerTwins.find(for: page, on: [source("a", Spy()), source("b", spy)])

        #expect(twins.map(\.serverID) == ["b"])
        #expect(twins.first?.serverName == "Server b")
        #expect(twins.first?.item.selectableMediaSources.map(\.id) == ["b1", "b2"])
    }

    /// The page's own server is never searched: it would only find the page again.
    @Test func thePagesOwnServerIsSkipped() async throws {
        let page = try movie("m", "The Matrix", server: "a", sources: ["a1"])
        let own = Spy()
        _ = await ServerTwins.find(for: page, on: [source("a", own)])
        #expect(own.searches.isEmpty)
    }

    /// Two servers in two metadata languages name the film differently; the original title is the
    /// one they share.
    @Test func aMissOnTheTitleRetriesWithTheOriginalTitle() async throws {
        let page = try movie("m", "Das Boot", server: "a", original: "The Boat", sources: ["a1"])
        let spy = Spy()
        spy.hits["The Boat"] = try movie("x", "The Boat", server: "b")
        spy.details["x"] = try movie("x", "The Boat", server: "b", sources: ["b1"])

        let twins = await ServerTwins.find(for: page, on: [source("b", spy)])

        #expect(spy.searches == ["Das Boot", "The Boat"])
        #expect(twins.count == 1)
    }

    /// A copy with nothing to play would add a heading with no rows under it.
    @Test func aCopyWithoutPlayableSourcesIsLeftOut() async throws {
        let page = try movie("m", "The Matrix", server: "a", sources: ["a1"])
        let spy = Spy()
        spy.hits["The Matrix"] = try movie("x", "The Matrix", server: "b")
        spy.details["x"] = try movie("x", "The Matrix", server: "b")
        #expect(await ServerTwins.find(for: page, on: [source("b", spy)]).isEmpty)
    }

    /// A server that does not answer costs the menu its copy, not the page its version button.
    @Test func aServerThatHangsIsDroppedAtTheDeadline() async throws {
        let page = try movie("m", "The Matrix", server: "a", sources: ["a1"])
        let slow = Spy()
        slow.stalls = true
        let fast = Spy()
        fast.hits["The Matrix"] = try movie("y", "The Matrix", server: "c")
        fast.details["y"] = try movie("y", "The Matrix", server: "c", sources: ["c1"])

        let clock = ContinuousClock()
        let started = clock.now
        let twins = await ServerTwins.find(for: page, on: [source("b", slow), source("c", fast)], deadline: .milliseconds(200))

        #expect(twins.map(\.serverID) == ["c"])
        #expect(clock.now - started < .seconds(5))
    }

    /// Without a provider id there is nothing to tell the same film from a namesake.
    @Test func aFilmWithoutProviderIDsIsNotLookedUp() async throws {
        let page = try movie("m", "Home Video", server: "a", tmdb: nil, sources: ["a1"])
        let spy = Spy()
        #expect(await ServerTwins.find(for: page, on: [source("b", spy)]).isEmpty)
        #expect(spy.searches.isEmpty)
    }
}

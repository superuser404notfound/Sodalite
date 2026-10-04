import Foundation
import Testing
@testable import Sodalite

@MainActor
struct HomeMergerTests {
    /// Builds an item; `extra` is raw JSON members appended to the object.
    private func item(_ id: String, server: String, type: String = "Movie", _ extra: String = "") throws -> JellyfinItem {
        let tail = extra.isEmpty ? "" : ",\(extra)"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)","ServerId":"\#(server)"\#(tail)}"#.utf8))
    }

    @Test func oneListComesBackUnchanged() throws {
        let list = [try item("b", server: "a"), try item("a", server: "a")]
        let merged = HomeMerger.merge([list], type: .allMovies, mergedContinueWatching: false)
        #expect(merged.map(\.id) == ["b", "a"])
    }

    @Test func continueWatchingIsOneTimeline() throws {
        let a = [try item("a1", server: "a", #""UserData":{"LastPlayedDate":"2026-10-01T20:00:00Z","PlaybackPositionTicks":5}"#),
                 try item("a2", server: "a", #""UserData":{"LastPlayedDate":"2026-09-01T20:00:00Z","PlaybackPositionTicks":5}"#)]
        let b = [try item("b1", server: "b", #""UserData":{"LastPlayedDate":"2026-09-15T20:00:00Z","PlaybackPositionTicks":5}"#)]
        let merged = HomeMerger.merge([a, b], type: .continueWatching, mergedContinueWatching: false)
        #expect(merged.map(\.id) == ["a1", "b1", "a2"])
    }

    @Test func mergedContinueWatchingPutsResumeFirstThenNextUpRoundRobin() throws {
        let a = [try item("ra", server: "a", #""UserData":{"LastPlayedDate":"2026-09-01T00:00:00Z","PlaybackPositionTicks":9}"#),
                 try item("na1", server: "a", type: "Episode"), try item("na2", server: "a", type: "Episode")]
        let b = [try item("rb", server: "b", #""UserData":{"LastPlayedDate":"2026-10-01T00:00:00Z","PlaybackPositionTicks":9}"#),
                 try item("nb1", server: "b", type: "Episode")]
        let merged = HomeMerger.merge([a, b], type: .continueWatching, mergedContinueWatching: true)
        #expect(merged.map(\.id) == ["rb", "ra", "na1", "nb1", "na2"])
    }

    @Test func nextUpIsRoundRobinInSourceOrder() throws {
        let a = [try item("a1", server: "a"), try item("a2", server: "a"), try item("a3", server: "a")]
        let b = [try item("b1", server: "b")]
        #expect(HomeMerger.merge([a, b], type: .nextUp, mergedContinueWatching: false).map(\.id) == ["a1", "b1", "a2", "a3"])
    }

    @Test func latestMoviesSortByDateCreated() throws {
        let a = [try item("old", server: "a", #""DateCreated":"2026-01-01T00:00:00.0000000Z""#)]
        let b = [try item("new", server: "b", #""DateCreated":"2026-09-01T00:00:00.0000000Z""#),
                 try item("none", server: "b")]
        #expect(HomeMerger.merge([a, b], type: .latestMovies, mergedContinueWatching: false).map(\.id) == ["new", "old", "none"])
    }

    @Test func sortNameIsCaseInsensitiveAndFallsBackToName() throws {
        let a = [try item("b", server: "a", #""SortName":"beta""#)]
        let b = [try item("A", server: "b"), try item("c", server: "b", #""SortName":"Gamma""#)]
        #expect(HomeMerger.merge([a, b], type: .allMovies, mergedContinueWatching: false).map(\.id) == ["A", "b", "c"])
    }

    @Test func topRatedSortsByRatingDescending() throws {
        let a = [try item("seven", server: "a", #""CommunityRating":7.0"#)]
        let b = [try item("nine", server: "b", #""CommunityRating":9.1"#)]
        #expect(HomeMerger.merge([a, b], type: .topRatedMovies, mergedContinueWatching: false).map(\.id) == ["nine", "seven"])
    }

    @Test func sameTitleOnTwoServersCollapsesToTheActiveCopy() throws {
        let a = [try item("ma", server: "a", #""ProviderIds":{"Tmdb":"603"},"SortName":"matrix""#)]
        let b = [try item("mb", server: "b", #""ProviderIds":{"tmdb":"603"},"SortName":"matrix""#)]
        let merged = HomeMerger.merge([a, b], type: .allMovies, mergedContinueWatching: false)
        #expect(merged.map(\.originKey) == ["a|ma"])
    }

    @Test func winnerIsTheCopyWithProgress() throws {
        let a = [try item("ma", server: "a", #""ProviderIds":{"Imdb":"tt0133093"},"SortName":"matrix""#)]
        let b = [try item("mb", server: "b", #""ProviderIds":{"Imdb":"tt0133093"},"SortName":"matrix","UserData":{"PlaybackPositionTicks":42}"#)]
        let merged = HomeMerger.merge([a, b], type: .allMovies, mergedContinueWatching: false)
        #expect(merged.map(\.originKey) == ["b|mb"])
    }

    @Test func aMovieAndASeriesWithTheSameTmdbNumberStayApart() throws {
        let a = [try item("m", server: "a", #""ProviderIds":{"Tmdb":"1"}"#)]
        let b = [try item("s", server: "b", type: "Series", #""ProviderIds":{"Tmdb":"1"}"#)]
        #expect(HomeMerger.merge([a, b], type: .favorites, mergedContinueWatching: false).count == 2)
    }

    @Test func collectionsAreNeverDeduped() throws {
        let a = [try item("ca", server: "a", type: "BoxSet", #""ProviderIds":{"Tmdb":"9"},"SortName":"x""#)]
        let b = [try item("cb", server: "b", type: "BoxSet", #""ProviderIds":{"Tmdb":"9"},"SortName":"x""#)]
        #expect(HomeMerger.merge([a, b], type: .collections, mergedContinueWatching: false).count == 2)
    }

    @Test func truncatesToTheRowsQueryLimit() throws {
        let a = (0..<12).map { try! item("a\($0)", server: "a") }
        let b = (0..<12).map { try! item("b\($0)", server: "b") }
        #expect(HomeMerger.merge([a, b], type: .nextUp, mergedContinueWatching: false).count == 16)
        #expect(HomeMerger.merge([Array(a.prefix(2)), Array(b.prefix(1))], type: .nextUp, mergedContinueWatching: false).count == 3)
    }

    @Test func foldedRowsMergeRoundRobin() {
        #expect(HomeMerger.order(for: .latestShows, mergedContinueWatching: false) == .roundRobin)
        #expect(HomeMerger.order(for: .recentlyReleasedShows, mergedContinueWatching: false) == .roundRobin)
        #expect(HomeMerger.order(for: .libraryLatest, mergedContinueWatching: false) == .roundRobin)
    }
}

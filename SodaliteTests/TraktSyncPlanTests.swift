import Foundation
import Testing
@testable import Sodalite

@MainActor
struct TraktSyncPlanTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func movie(_ id: String, tmdb: Int, played: Bool, at: Date? = nil, rating: Double? = nil) -> TraktLocalMovie {
        TraktLocalMovie(itemID: id, ids: TraktIDs(tmdb: tmdb), played: played, lastPlayed: at, rating: rating)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TraktClient.makeDecoder().decode(type, from: Data(json.utf8))
    }

    private func traktMovies(_ entries: [(Int, String)]) throws -> [TraktWatchedMovie] {
        let body = entries.map { #"{"last_watched_at":"\#($0.1)","movie":{"ids":{"tmdb":\#($0.0)}}}"# }
        return try decode([TraktWatchedMovie].self, "[\(body.joined(separator: ","))]")
    }

    @Test func playedLocallyButNotOnTraktIsPushed() {
        let plan = TraktSyncPlan.watched(
            movies: [movie("a", tmdb: 1, played: true, at: now)], series: [], episodes: [],
            trakt: TraktWatchedSnapshot(), pull: nil, pushSince: nil)
        #expect(plan.push.movies.map(\.ids.tmdb) == [1])
        #expect(plan.markPlayed.isEmpty)
    }

    @Test func watchedOnTraktIsPulledOnlyWhenRecent() throws {
        let watched = try traktMovies([(1, "2026-01-01T00:00:00.000Z"), (2, "2027-03-01T00:00:00.000Z")])
        let since = TraktDate.parse("2027-01-01T00:00:00.000Z")
        let full = TraktWatchedSnapshot(movies: watched, shows: [])
        let pull = TraktWatchedSnapshot(movies: watched, shows: [], since: since)
        let plan = TraktSyncPlan.watched(
            movies: [movie("old", tmdb: 1, played: false), movie("new", tmdb: 2, played: false)],
            series: [], episodes: [], trakt: full, pull: pull, pushSince: nil)
        // "old" was unmarked in Jellyfin after Trakt saw it; only a newer Trakt watch brings it back.
        #expect(plan.markPlayed == ["new"])
    }

    @Test func nothingIsEverUnmarked() throws {
        let plan = TraktSyncPlan.watched(
            movies: [movie("a", tmdb: 1, played: true, at: now)], series: [], episodes: [],
            trakt: TraktWatchedSnapshot(movies: try traktMovies([(1, "2026-01-01T00:00:00Z")]), shows: []),
            pull: TraktWatchedSnapshot(), pushSince: nil)
        #expect(plan.markPlayed.isEmpty)
        #expect(plan.push.isEmpty)
    }

    @Test func oldLocalWatchIsNotPushedAfterTheFirstSync() {
        let plan = TraktSyncPlan.watched(
            movies: [movie("old", tmdb: 1, played: true, at: now - 30 * day),
                     movie("new", tmdb: 2, played: true, at: now)],
            series: [], episodes: [], trakt: TraktWatchedSnapshot(), pull: nil, pushSince: now - day)
        #expect(plan.push.movies.map(\.ids.tmdb) == [2])
    }

    @Test func episodesMatchThroughTheSeriesIDsAndNumbers() throws {
        let shows = try decode([TraktWatchedShow].self, #"""
        [{"show":{"ids":{"tvdb":77}},"seasons":[{"number":1,"episodes":[
          {"number":1,"last_watched_at":"2027-02-01T00:00:00.000Z"}]}]}]
        """#)
        let snapshot = TraktWatchedSnapshot(movies: [], shows: shows)
        let series = [TraktLocalSeries(itemID: "s", ids: TraktIDs(tmdb: 5, tvdb: 77), rating: nil)]
        let episodes = [
            TraktLocalEpisode(itemID: "e1", seriesID: "s", season: 1, number: 1, played: false, lastPlayed: nil),
            TraktLocalEpisode(itemID: "e2", seriesID: "s", season: 1, number: 2, played: true, lastPlayed: now),
        ]
        let plan = TraktSyncPlan.watched(movies: [], series: series, episodes: episodes,
                                         trakt: snapshot, pull: snapshot, pushSince: nil)
        #expect(plan.markPlayed == ["e1"])
        #expect(plan.push.shows.count == 1)
        #expect(plan.push.shows.first?.seasons?.first?.episodes?.map(\.number) == [2])
    }

    @Test func aRecordedPushIsNotPushedTwice() {
        var snapshot = TraktWatchedSnapshot()
        let first = TraktSyncPlan.watched(movies: [movie("a", tmdb: 1, played: true, at: now)], series: [],
                                          episodes: [], trakt: snapshot, pull: nil, pushSince: nil)
        snapshot.record(first.push)
        let second = TraktSyncPlan.watched(movies: [movie("a", tmdb: 1, played: true, at: now)], series: [],
                                           episodes: [], trakt: snapshot, pull: nil, pushSince: nil)
        #expect(second.push.isEmpty)
    }

    @Test func aPushTraktDidNotTakeIsNotSentAgainAfterARebuild() throws {
        var snapshot = TraktWatchedSnapshot()
        let first = TraktSyncPlan.watched(movies: [movie("a", tmdb: 1, played: true, at: now)], series: [],
                                          episodes: [], trakt: snapshot, pull: nil, pushSince: nil)
        snapshot.record(first.push)
        // The next sync rebuilds from Trakt, which never listed the movie, and carries `pushed` over.
        var rebuilt = TraktWatchedSnapshot(movies: [], shows: [])
        rebuilt.pushed = snapshot.pushed
        let second = TraktSyncPlan.watched(movies: [movie("a", tmdb: 1, played: true, at: now)], series: [],
                                           episodes: [], trakt: rebuilt, pull: nil, pushSince: nil)
        #expect(second.push.isEmpty)
    }

    @Test func unwatchingForgetsThePush() {
        var snapshot = TraktWatchedSnapshot()
        var body = TraktSyncBody()
        body.movies = [.init(ids: TraktIDs(tmdb: 1))]
        snapshot.record(body)
        snapshot.forget(body)
        #expect(!snapshot.contains(movie: TraktIDs(tmdb: 1)))
    }

    @Test func aSnapshotCachedBeforePushedExistedStillLoads() throws {
        let old = #"{"movies":["tmdb:1"],"episodes":[]}"#
        let snapshot = try JSONDecoder().decode(TraktWatchedSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.contains(movie: TraktIDs(tmdb: 1)))
    }

    @Test func ratingsFillOnlyTheEmptySide() throws {
        let rated = try decode([TraktRatedItem].self, #"""
        [{"rating":8,"movie":{"ids":{"tmdb":1}}},{"rating":3,"movie":{"ids":{"tmdb":2}}}]
        """#)
        let plan = TraktSyncPlan.ratings(
            movies: [movie("a", tmdb: 1, played: false), movie("b", tmdb: 2, played: false, rating: 9),
                     movie("c", tmdb: 3, played: false, rating: 6.6)],
            series: [], traktRatings: rated)
        #expect(plan.setLocal == ["a": 8])
        #expect(plan.push.movies.map(\.rating) == [7])
    }

    @Test func episodeRatingsFillTheEmptySide() throws {
        let rated = try decode([TraktRatedItem].self, #"""
        [{"rating":9,"show":{"ids":{"tvdb":77}},"episode":{"season":1,"number":1}}]
        """#)
        let series = [TraktLocalSeries(itemID: "s", ids: TraktIDs(tvdb: 77), rating: nil)]
        let episodes = [
            TraktLocalEpisode(itemID: "e1", seriesID: "s", season: 1, number: 1, played: true, lastPlayed: nil),
            TraktLocalEpisode(itemID: "e2", seriesID: "s", season: 1, number: 2, played: true, lastPlayed: nil, rating: 4),
        ]
        let plan = TraktSyncPlan.ratings(movies: [], series: series, episodes: episodes, traktRatings: rated)
        #expect(plan.setLocal == ["e1": 9])
        #expect(plan.push.shows.first?.seasons?.first?.episodes?.map(\.rating) == [4])
    }

    @Test func aNewerPauseElsewhereBecomesTheResumePosition() throws {
        let paused = try decode([TraktPlaybackItem].self, #"""
        [{"progress":50,"paused_at":"2027-01-10T20:00:00.000Z","movie":{"ids":{"tmdb":1}}},
         {"progress":50,"paused_at":"2027-01-10T20:00:00.000Z","movie":{"ids":{"tmdb":2}}},
         {"progress":50,"paused_at":"2027-01-10T20:00:00.000Z","movie":{"ids":{"tmdb":3}}}]
        """#)
        let pausedAt = try #require(TraktDate.parse("2027-01-10T20:00:00.000Z"))
        let hour: Int64 = 3600 * 10_000_000
        let movies = [
            TraktLocalMovie(itemID: "older", ids: TraktIDs(tmdb: 1), played: false,
                            lastPlayed: pausedAt - day, rating: nil, runTimeTicks: 2 * hour),
            // Jellyfin's own last play is the same moment: Sodalite sent that pause itself.
            TraktLocalMovie(itemID: "own", ids: TraktIDs(tmdb: 2), played: false,
                            lastPlayed: pausedAt, rating: nil, runTimeTicks: 2 * hour),
            TraktLocalMovie(itemID: "done", ids: TraktIDs(tmdb: 3), played: true,
                            lastPlayed: nil, rating: nil, runTimeTicks: 2 * hour),
        ]
        let result = TraktSyncPlan.playback(movies: movies, series: [], episodes: [], trakt: paused)
        #expect(Array(result.keys) == ["older"])
        #expect(result["older"]?.ticks == hour)
    }

    @Test func ratingScaleMapsToTrakt() {
        #expect(TraktRating.trakt(fromJellyfin: nil) == nil)
        #expect(TraktRating.trakt(fromJellyfin: 0) == nil)
        #expect(TraktRating.trakt(fromJellyfin: 1) == 1)
        #expect(TraktRating.trakt(fromJellyfin: 10) == 10)
        #expect(TraktRating.trakt(fromJellyfin: 12) == 10)
    }

    @Test func batchesSplitLargeBodies() {
        var body = TraktSyncBody()
        body.movies = (1...450).map { .init(ids: TraktIDs(tmdb: $0)) }
        let batches = TraktSyncPlan.batches(body, size: 200)
        #expect(batches.map(\.movies.count) == [200, 200, 50])
    }

    @Test func traktAndJellyfinDatesParse() {
        #expect(TraktDate.parse("2014-09-01T09:10:11.000Z") != nil)
        #expect(TraktDate.parse("2026-10-01T20:00:00Z") != nil)
        #expect(TraktDate.parse("2026-10-01T20:00:00.1234567Z") != nil)
    }

    @Test func tokensRefreshADayEarly() {
        let tokens = TraktTokens(accessToken: "a", refreshToken: "r", expiresAt: now + 2 * day)
        #expect(!tokens.needsRefresh(now: now))
        #expect(tokens.needsRefresh(now: now + 1.5 * day))
    }

    @Test func storedSessionSurvivesMissingNewFields() throws {
        let json = #"{"tokens":{"accessToken":"a","refreshToken":"r","expiresAt":0},"username":"u"}"#
        let session = try JSONDecoder().decode(TraktSession.self, from: Data(json.utf8))
        #expect(session.options == TraktOptions())
        #expect(session.cursors == TraktSyncCursors())
    }
}

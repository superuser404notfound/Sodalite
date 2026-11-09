import Foundation
import Testing
@testable import Sodalite

struct ExternalRatingsTests {
    @Test func namedScoresReplaceTheStar() {
        let shown = RatingDisplay.resolve(
            communityRating: 7.8, criticRating: nil,
            external: ExternalRatings(tmdb: 7.8, imdb: 7.6, rottenTomatoes: 91),
            awaitingExternal: false
        )
        #expect(shown == RatingDisplay(tmdb: 7.8, imdb: 7.6, community: nil, rottenTomatoes: 91))
    }

    @Test func starStandsInWithoutNamedScores() {
        let none = RatingDisplay.resolve(communityRating: 6.5, criticRating: 40, external: nil, awaitingExternal: false)
        #expect(none == RatingDisplay(tmdb: nil, imdb: nil, community: 6.5, rottenTomatoes: 40))

        // RT alone is not a named community score, so the star stays.
        let rtOnly = RatingDisplay.resolve(
            communityRating: 6.5, criticRating: nil,
            external: ExternalRatings(rottenTomatoes: 80), awaitingExternal: false
        )
        #expect(rtOnly.community == 6.5)
        #expect(rtOnly.rottenTomatoes == 80)
    }

    @Test func starWaitsForAPendingFetch() {
        let shown = RatingDisplay.resolve(communityRating: 6.5, criticRating: 55, external: nil, awaitingExternal: true)
        #expect(shown.community == nil)
        #expect(shown.rottenTomatoes == 55)
    }

    @Test func serverCriticScoreWinsOverSeerr() {
        let shown = RatingDisplay.resolve(
            communityRating: nil, criticRating: 72,
            external: ExternalRatings(rottenTomatoes: 70), awaitingExternal: false
        )
        #expect(shown.rottenTomatoes == 72)
    }

    @Test func zeroMeansUnrated() {
        // TMDB reports 0 for a title nobody voted on.
        let shown = RatingDisplay.resolve(
            communityRating: 0, criticRating: nil,
            external: ExternalRatings(tmdb: 0, imdb: nil), awaitingExternal: false
        )
        #expect(shown == RatingDisplay(tmdb: nil, imdb: nil, community: nil, rottenTomatoes: nil))
    }

    @Test func decodesCombinedRatings() throws {
        let json = Data("""
        {"rt":{"title":"The Matrix","year":1999,"criticsRating":"Certified Fresh","criticsScore":83,
        "audienceRating":"Upright","audienceScore":85,"url":"https://www.rottentomatoes.com/m/matrix"},
        "imdb":{"title":"The Matrix","url":"https://www.imdb.com/title/tt0133093","criticsScore":8.7,"criticsScoreCount":2100000}}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let ratings = try decoder.decode(SeerrRatings.self, from: json)
        #expect(ratings.rt?.criticsScore == 83)
        #expect(ratings.imdb?.criticsScore == 8.7)

        let rtOnly = try decoder.decode(SeerrRatings.self, from: Data(#"{"rt":{"criticsScore":60}}"#.utf8))
        #expect(rtOnly.imdb == nil)
    }
}

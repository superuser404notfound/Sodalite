import Testing
@testable import Sodalite

/// Seerr's person search ranks by TMDB popularity and returns partial-name hits, so the rules that
/// pick one of its results decide whether a page shows the right filmography or a stranger's
/// (Sodalite#143).
struct PersonTMDBMatchTests {
    private func person(_ id: Int, _ name: String, knownFor: [Int] = []) -> SeerrPersonSearchResult {
        SeerrPersonSearchResult(
            id: id,
            name: name,
            knownFor: knownFor.map { SeerrMedia.stub(tmdbID: $0, mediaType: .movie) }
        )
    }

    @Test func noCandidatesResolveToNothing() {
        #expect(PersonTMDBMatch.resolve(in: [], name: "Mindy Kaling", sourceTMDBID: nil) == nil)
    }

    @Test func oneExactNameWins() {
        let hits = [person(55638, "Mindy Kaling"), person(9, "Mindy Kaling Fan Channel")]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "Mindy Kaling", sourceTMDBID: nil) == 55638)
    }

    /// A partial hit is what TMDB search returns for almost any query; taking it would attach the
    /// wrong filmography to the page.
    @Test func aPartialNameIsNotAMatch() {
        let hits = [person(9, "Chris Evanson")]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "Chris Evans", sourceTMDBID: nil) == nil)
    }

    @Test func punctuationAndDiacriticsDoNotSeparateAPerson() {
        let hits = [person(38334, "Penélope Cruz")]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "penelope cruz", sourceTMDBID: nil) == 38334)
    }

    /// Two people of the same name cannot be told apart by name alone, and guessing is worse than
    /// showing nothing.
    @Test func twoSameNamedPeopleWithoutASourceTitleResolveToNothing() {
        let hits = [person(1, "David Jones"), person(2, "David Jones")]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "David Jones", sourceTMDBID: nil) == nil)
    }

    /// The title the tap came from is the tie-breaker: only one of them is credited on it.
    @Test func theSourceTitleTellsSameNamedPeopleApart() {
        let hits = [person(1, "David Jones", knownFor: [500]), person(2, "David Jones", knownFor: [77])]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "David Jones", sourceTMDBID: 77) == 2)
    }

    /// knownFor carries TMDB's best-known credits, not every credit, so the tie-breaker often has
    /// nothing to say. It stays a tie then.
    @Test func aSourceTitleNoCandidateIsKnownForKeepsTheTie() {
        let hits = [person(1, "David Jones", knownFor: [500]), person(2, "David Jones", knownFor: [77])]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "David Jones", sourceTMDBID: 999) == nil)
    }

    /// A single exact name needs no tie-breaker, and must not lose to one that finds nothing.
    @Test func aLoneExactNameSurvivesAnUnhelpfulSourceTitle() {
        let hits = [person(55638, "Mindy Kaling", knownFor: [500])]
        #expect(PersonTMDBMatch.resolve(in: hits, name: "Mindy Kaling", sourceTMDBID: 999) == 55638)
    }

    @Test func anEmptyNameNeverMatches() {
        #expect(PersonTMDBMatch.resolve(in: [person(1, "")], name: "  ", sourceTMDBID: nil) == nil)
    }
}

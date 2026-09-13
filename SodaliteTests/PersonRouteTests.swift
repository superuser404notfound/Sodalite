import Testing
@testable import Sodalite

struct PersonRouteTests {
    private func member(personID: Int?, jellyfinPersonID: String?) -> CastMember {
        CastMember(
            id: "cast-1",
            name: "Owen Wilson",
            role: "Lightning McQueen (voice)",
            imageURL: nil,
            personID: personID,
            jellyfinPersonID: jellyfinPersonID
        )
    }

    /// Jellyfin cast has no TMDB id at tap time, so identity has to come from the Jellyfin person id.
    /// Without it the route could not be pushed before the resolve, which is the whole point.
    @Test func jellyfinCastRoutesWithoutATmdbID() {
        let route = PersonRoute(member: member(personID: nil, jellyfinPersonID: "abc123"))
        #expect(route.tmdbID == nil)
        #expect(route.jellyfinPersonID == "abc123")
        #expect(route.id == "abc123")
    }

    @Test func seerrCastKeepsItsTmdbID() {
        let route = PersonRoute(member: member(personID: 887, jellyfinPersonID: nil))
        #expect(route.tmdbID == 887)
        #expect(route.id == "887")
    }

    /// Two different cast members must not collapse onto one navigation identity.
    @Test func routesStayDistinctPerMember() {
        let a = PersonRoute(member: member(personID: nil, jellyfinPersonID: "abc123"))
        let b = PersonRoute(member: member(personID: nil, jellyfinPersonID: "def456"))
        #expect(a.id != b.id)
    }

    /// The source title is a hint for the name resolve, not part of who the person is: the same
    /// cast member reached from two titles must not push two different pages (Sodalite#143).
    @Test func theSourceTitleTravelsWithoutChangingIdentity() {
        let m = member(personID: nil, jellyfinPersonID: "abc123")
        let fromMovie = PersonRoute(member: m, sourceTMDBID: 920)
        let fromSeries = PersonRoute(member: m, sourceTMDBID: 1399)
        #expect(fromMovie.sourceTMDBID == 920)
        #expect(fromMovie.id == fromSeries.id)
    }

    /// Neither id present (a source that only knows a name) still yields a usable identity
    /// rather than an empty string every member would share.
    @Test func nameCarriesIdentityAsALastResort() {
        let route = PersonRoute(member: member(personID: nil, jellyfinPersonID: nil))
        #expect(route.id == "Owen Wilson")
    }
}

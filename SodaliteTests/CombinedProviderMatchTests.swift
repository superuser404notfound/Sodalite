import Foundation
import Testing
@testable import Sodalite

@MainActor
struct CombinedProviderMatchTests {
    private func item(_ id: String, server: String, sort: String, tmdb: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(sort)","SortName":"\#(sort)","Type":"Movie","ServerId":"\#(server)","ProviderIds":{"Tmdb":"\#(tmdb)"}}"#.utf8))
    }

    @Test func firstServerWinsATmdbId() throws {
        let a = try item("a1", server: "a", sort: "x", tmdb: "1")
        let b = try item("b1", server: "b", sort: "x", tmdb: "1")
        let c = try item("b2", server: "b", sort: "y", tmdb: "2")
        let union = CombinedProviderMatch.unionTmdbMaps([["movie-1": a], ["movie-1": b, "movie-2": c]])
        #expect(union["movie-1"]?.serverID == "a")
        #expect(union["movie-2"]?.serverID == "b")
    }

    @Test func studioMatchesMergeAndDedupe() throws {
        let a = [try item("a1", server: "a", sort: "Zeta", tmdb: "9")]
        let b = [try item("b1", server: "b", sort: "Alpha", tmdb: "8"), try item("b2", server: "b", sort: "Zeta", tmdb: "9")]
        let merged = CombinedProviderMatch.mergeStudioMatches([a, b])
        #expect(merged.map(\.id) == ["b1", "a1"])
    }
}

import Foundation
import Testing
@testable import Sodalite

@Suite("GenreTilePick")
struct GenreTilePickTests {
    private func tag(_ id: String, _ name: String) throws -> NamedItem {
        try JSONDecoder().decode(NamedItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(name)"}"#.utf8))
    }

    private func item(_ id: String, genres: [String]?) throws -> JellyfinItem {
        var json: [String: Any] = ["Id": id, "Name": id, "Type": "Movie"]
        if let genres { json["Genres"] = genres }
        return try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func fieldsAddGenresOnce() {
        #expect(GenreTilePick.fields("") == "Genres")
        #expect(GenreTilePick.fields("ImageTags") == "ImageTags,Genres")
        #expect(GenreTilePick.fields("ImageTags,genres") == "ImageTags,genres")
    }

    /// The reported server: every probe answers with the same unfiltered item.
    @Test func ignoredFilterLeavesTilesWithoutArtwork() throws {
        let tags = [try tag("g1", "Action"), try tag("g2", "Comedy")]
        let same = try item("x", genres: ["Romance"])
        let picks = GenreTilePick.pick(tags: tags, candidates: ["g1": [same], "g2": [same]])
        #expect(picks.count == 2)
        #expect(picks["g1"]! == nil)
        #expect(picks["g2"]! == nil)
    }

    @Test func emptyProbeDropsTheTile() throws {
        let tags = [try tag("g1", "Action"), try tag("g2", "Western")]
        let picks = GenreTilePick.pick(tags: tags, candidates: ["g1": [try item("a", genres: ["Action"])], "g2": []])
        #expect(picks["g1"]??.id == "a")
        #expect(picks["g2"] == nil)
    }

    @Test func laterTilePrefersAnUnusedItem() throws {
        let tags = [try tag("g1", "Action"), try tag("g2", "Crime")]
        let both = try item("both", genres: ["Action", "Crime"])
        let crime = try item("crime", genres: ["crime"])
        let picks = GenreTilePick.pick(tags: tags, candidates: ["g1": [both], "g2": [both, crime]])
        #expect(picks["g1"]??.id == "both")
        #expect(picks["g2"]??.id == "crime")
    }

    @Test func repeatsOnlyWhenNothingElseMatches() throws {
        let tags = [try tag("g1", "Action"), try tag("g2", "Crime")]
        let both = try item("both", genres: ["Action", "Crime"])
        let picks = GenreTilePick.pick(tags: tags, candidates: ["g1": [both], "g2": [both, try item("n", genres: nil)]])
        #expect(picks["g2"]??.id == "both")
    }
}

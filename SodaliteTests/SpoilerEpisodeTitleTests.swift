import Foundation
import Testing
@testable import Sodalite

/// Robius (Discord, 2026-10-08): a game show names its contestants in the episode title.
@Suite("Spoiler episode titles")
struct SpoilerEpisodeTitleTests {

    private func episode(index: Int? = 12, series: String? = "Jeopardy!", percentage: Double? = nil) throws -> JellyfinItem {
        var json = #"{"Id":"e1","Name":"Alice vs. Bob","Type":"Episode","SeriesId":"s1","ParentIndexNumber":3"#
        if let index { json += #","IndexNumber":\#(index)"# }
        if let series { json += #","SeriesName":"\#(series)""# }
        if let percentage { json += #","UserData":{"PlayedPercentage":\#(percentage)}"# }
        json += "}"
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func policy(titles: Bool = true, overrides: [String: Bool] = [:], enabled: Bool = true) -> SpoilerPolicy {
        SpoilerPolicy(enabled: enabled, hideEpisodes: true, hideMovies: false, userID: "u1",
                      revealedKeys: [], seriesOverrides: overrides, hideEpisodeTitles: titles)
    }

    private func shelfItem(series: String = "s1", percentage: Double? = nil) throws -> TopShelfItem {
        var json = #"{"Id":"e1","Name":"Alice vs. Bob","Type":"Episode","SeriesName":"Jeopardy!","SeriesId":"\#(series)","ParentIndexNumber":3,"IndexNumber":12"#
        if let percentage { json += #","UserData":{"PlayedPercentage":\#(percentage)}"# }
        json += "}"
        return try JSONDecoder().decode(TopShelfItem.self, from: Data(json.utf8))
    }

    @Test("a veiled name stands in as its number, an unnumbered one as a bare word")
    func displayNameFallback() throws {
        #expect(policy().displayName(of: try episode()) != "Alice vs. Bob")
        #expect(policy().displayName(of: try episode()).contains("12"))
        #expect(!policy().displayName(of: try episode(index: nil)).isEmpty)
        #expect(policy(titles: false).displayName(of: try episode()) == "Alice vs. Bob")
    }

    @Test("the player keeps the series and the numbers and loses only the name")
    func playerTitleLines() throws {
        let lines = PlayerTitleLines(item: try episode(), spoilerPolicy: policy())
        #expect(lines.header == "Jeopardy!")
        #expect(lines.subtitle == "S3, E12")
        #expect(PlayerTitleLines(item: try episode()).subtitle == "S3, E12 · Alice vs. Bob")
    }

    @Test("without a series name the header falls back to the stand-in, not the name")
    func playerHeaderWithoutSeries() throws {
        let lines = PlayerTitleLines(item: try episode(series: nil), spoilerPolicy: policy())
        #expect(lines.header != "Alice vs. Bob")
    }

    @Test("the shelf mirror carries this profile's rules and reveals only")
    func mirrorIsScopedToTheProfile() {
        let p = SpoilerPolicy(enabled: false, hideEpisodes: true, hideMovies: false, userID: "u1",
                              revealedKeys: ["u1|e9", "u2|e8"],
                              seriesOverrides: ["u1|s1": true, "u2|s2": true], hideEpisodeTitles: true)
        let veil = p.topShelfTitleVeil
        #expect(veil.hidesByDefault == false)
        #expect(veil.seriesRules == ["s1": true])
        #expect(veil.revealedItemIDs == ["e9"])
        #expect(policy(titles: false).topShelfTitleVeil == .off)
    }

    @Test("a shelf cell drops the name of an unstarted veiled episode and keeps the rest")
    func shelfTitle() throws {
        let veil = TopShelfTitleVeil(hidesByDefault: false, seriesRules: ["s1": true], revealedItemIDs: [])
        #expect(try shelfItem().topShelfTitle(veil: veil) == "Jeopardy! · S3, E12")
        #expect(try shelfItem().topShelfTitle() == "Jeopardy! · S3, E12 · Alice vs. Bob")
        #expect(try shelfItem(series: "s2").topShelfTitle(veil: veil).hasSuffix("Alice vs. Bob"))
        #expect(try shelfItem(percentage: 30).topShelfTitle(veil: veil).hasSuffix("Alice vs. Bob"))
        let revealed = TopShelfTitleVeil(hidesByDefault: true, seriesRules: [:], revealedItemIDs: ["e1"])
        #expect(try shelfItem().topShelfTitle(veil: revealed).hasSuffix("Alice vs. Bob"))
    }
}

import Foundation
import Testing
@testable import Sodalite

@MainActor
struct CombinedHomeModelTests {
    private func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func cardFieldsCarryWhatTheMergerSortsAndDedupesBy() {
        let fields = Set(JellyfinEndpoint.homeRowFields.split(separator: ",").map(String.init))
        #expect(fields.isSuperset(of: ["DateCreated", "SortName", "ProviderIds"]))
        #expect(!fields.contains("MediaStreams"))
    }

    @Test func itemDecodesDateCreated() throws {
        let decoded = try item(#"{"Id":"a","Name":"A","Type":"Movie","DateCreated":"2026-09-01T10:00:00.0000000Z"}"#)
        #expect(decoded.dateCreated == "2026-09-01T10:00:00.0000000Z")
    }

    @Test func sameIdOnTwoServersSurvivesTheRowDedupe() throws {
        let a = try item(#"{"Id":"x","Name":"A","Type":"Movie","ServerId":"srv-a"}"#)
        let b = try item(#"{"Id":"x","Name":"B","Type":"Movie","ServerId":"srv-b"}"#)
        let row = HomeRowData(type: .latestMovies, items: [a, b, a])
        #expect(row.items.map(\.originKey) == ["srv-a|x", "srv-b|x"])
    }

    @Test func rowCarriesItsServer() {
        let row = HomeRowData(type: .libraryLatest, items: [], libraryID: "lib", libraryName: "Movies", serverID: "srv-b")
        #expect(row.serverID == "srv-b")
    }
}

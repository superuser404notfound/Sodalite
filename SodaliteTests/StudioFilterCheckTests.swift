import Foundation
import Testing
@testable import Sodalite

@Suite("StudioFilterCheck")
struct StudioFilterCheckTests {
    private func item(_ id: String, studios: [String]?) throws -> JellyfinItem {
        var json: [String: Any] = ["Id": id, "Name": id, "Type": "Movie"]
        if let studios { json["Studios"] = studios.map { ["Name": $0, "Id": UUID().uuidString] } }
        return try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func fieldsAddStudiosOnce() {
        #expect(StudioFilterCheck.fields("") == "Studios")
        #expect(StudioFilterCheck.fields("ImageTags") == "ImageTags,Studios")
        #expect(StudioFilterCheck.fields("ImageTags,Studios") == "ImageTags,Studios")
    }

    @Test func matchingAnswerIsLeftAlone() throws {
        let response = JellyfinItemsResponse(
            items: [try item("a", studios: ["Netflix"]), try item("b", studios: ["HBO", "netflix"])],
            totalRecordCount: 412
        )
        let result = StudioFilterCheck.filter(response, studioNames: ["Netflix"])
        #expect(result.dropped == 0)
        #expect(result.response.items.map(\.id) == ["a", "b"])
        #expect(result.response.totalRecordCount == 412)
    }

    /// AIOMetadata: the filter is ignored and every item carries an empty studio list.
    @Test func ignoredFilterIsDropped() throws {
        let response = JellyfinItemsResponse(
            items: [try item("a", studios: []), try item("b", studios: nil), try item("c", studios: ["Netflix"])],
            totalRecordCount: 9000
        )
        let result = StudioFilterCheck.filter(response, studioNames: ["Netflix", "Netflix Studios"])
        #expect(result.dropped == 2)
        #expect(result.response.items.map(\.id) == ["c"])
        #expect(result.response.totalRecordCount == 1)
    }
}

import Foundation
import Testing
@testable import Sodalite

@Suite("Top Shelf rows")
struct TopShelfRowsTests {

    private static func item(_ id: String) throws -> TopShelfItem {
        let json = #"{"Id":"\#(id)","Name":"\#(id)","Type":"Episode"}"#
        return try JSONDecoder().decode(TopShelfItem.self, from: Data(json.utf8))
    }

    /// Older servers ignore `EnableResumable=false`, so a part-watched episode comes back from both
    /// queries. Kept twice, the artwork pass could never cover every cell and dropped the burned-in
    /// artwork on every refresh.
    @Test("an item in Continue Watching is dropped from Next Up")
    func resumeWinsOverNextUp() throws {
        let rows = TopShelfItem.shelfRows(resume: [try Self.item("a"), try Self.item("b")],
                                          nextUp: [try Self.item("b"), try Self.item("c")])
        #expect(rows.resume.map(\.id) == ["a", "b"])
        #expect(rows.nextUp.map(\.id) == ["c"])
    }

    @Test("a repeat inside one row keeps its first position")
    func repeatsInsideARow() throws {
        let rows = TopShelfItem.shelfRows(resume: [try Self.item("a"), try Self.item("a")],
                                          nextUp: [try Self.item("c"), try Self.item("c")])
        #expect(rows.resume.map(\.id) == ["a"])
        #expect(rows.nextUp.map(\.id) == ["c"])
    }
}

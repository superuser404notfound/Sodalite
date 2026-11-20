import Foundation
import Testing
@testable import Sodalite

struct ItemQueryNameFilterTests {
    @Test func nameFiltersAreOmittedByDefault() {
        let items = ItemQuery(fields: "").toQueryItems()
        #expect(!items.contains { $0.name == "NameLessThan" || $0.name == "NameStartsWithOrGreater" })
    }

    @Test func nameFiltersAreSent() {
        var query = ItemQuery(fields: "")
        query.nameLessThan = "p"
        query.nameStartsWithOrGreater = "q"
        let items = query.toQueryItems()
        #expect(items.contains(URLQueryItem(name: "NameLessThan", value: "p")))
        #expect(items.contains(URLQueryItem(name: "NameStartsWithOrGreater", value: "q")))
    }
}

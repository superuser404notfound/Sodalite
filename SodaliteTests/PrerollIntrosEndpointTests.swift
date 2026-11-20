import Testing
import Foundation
@testable import Sodalite

struct PrerollIntrosEndpointTests {
    @Test("the intros endpoint is the user-scoped one LocalTrailers also uses")
    func introsPathAndQuery() {
        let endpoint = JellyfinEndpoint.intros(userID: "u1", itemID: "m1")
        #expect(endpoint.path == "/Users/u1/Items/m1/Intros")
        #expect(endpoint.method == .get)
        let query = Dictionary(uniqueKeysWithValues: (endpoint.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(query["UserId"] == "u1")
        #expect(query["Fields"] == JellyfinEndpoint.detailFields)
    }
}

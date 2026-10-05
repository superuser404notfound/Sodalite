import Testing
import Foundation
@testable import Sodalite

@MainActor
struct MyRequestsDiffTests {
    static let movieRequestJSON = """
    {"id":7,"status":2,"createdAt":"2026-10-05T09:12:33.000Z","updatedAt":"2026-10-05T09:20:00.000Z",
     "type":"movie","is4k":false,
     "media":{"id":3,"tmdbId":550,"mediaType":"movie","status":5,"jellyfinMediaId":"abc123"},
     "requestedBy":{"id":4,"displayName":"kid"}}
    """

    @Test func requestMediaDecodesJellyfinID() throws {
        let request = try JSONDecoder().decode(SeerrRequest.self, from: Data(Self.movieRequestJSON.utf8))
        #expect(request.media?.jellyfinMediaId == "abc123")
    }

    @Test func myRequestsSortByModificationReachesQuery() throws {
        let items = SeerrEndpoint.myRequests(userID: 4, take: 50, skip: 0, sort: .modified).queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "sort", value: "modified")))
        #expect(items.contains(URLQueryItem(name: "requestedBy", value: "4")))
    }
}

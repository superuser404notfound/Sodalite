import Testing
import Foundation
@testable import Sodalite

@MainActor
struct AppIconBadgeTests {
    @Test func sumsAdminQueueAndOwnEvents() {
        #expect(AppIconBadge.count(pendingApproval: 3, adminNotificationsOn: true, unseenMine: 2) == 5)
    }

    @Test func adminShareOnlyWhenAdminNotificationsOn() {
        #expect(AppIconBadge.count(pendingApproval: 3, adminNotificationsOn: false, unseenMine: 2) == 2)
        #expect(AppIconBadge.count(pendingApproval: nil, adminNotificationsOn: true, unseenMine: 0) == 0)
    }

    @Test func statusTextNamesOnlyRequestedSeasons() {
        let event = MyRequestEvent(requestID: 1, kind: .available, mediaType: .tv, tmdbID: 1, seasons: [1, 3], jellyfinItemID: nil, title: nil, posterPath: nil, date: .now)
        #expect(event.statusText.contains("1"))
        #expect(event.statusText.contains("3"))
        let movie = MyRequestEvent(requestID: 2, kind: .available, mediaType: .movie, tmdbID: 1, seasons: [], jellyfinItemID: nil, title: nil, posterPath: nil, date: .now)
        #expect(!movie.statusText.isEmpty)
    }
}

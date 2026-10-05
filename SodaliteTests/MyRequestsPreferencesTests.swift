import Testing
import Foundation
@testable import Sodalite

@MainActor
struct MyRequestsPreferencesTests {
    private func makePrefs() -> SeerrNotificationPreferences {
        let suite = "MyRequestsPreferencesTests.\(UUID().uuidString)"
        return SeerrNotificationPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func toggleDefaultsOnAndIsPerProfile() {
        let prefs = makePrefs()
        #expect(prefs.notifyMyRequests(scope: "s_a") == true)
        prefs.setNotifyMyRequests(false, scope: "s_a")
        #expect(prefs.notifyMyRequests(scope: "s_a") == false)
        #expect(prefs.notifyMyRequests(scope: "s_b") == true)
    }

    @Test func snapshotAndUnseenRoundTripPerProfile() {
        let prefs = makePrefs()
        let snap = MyRequestsSnapshot(baselineDate: Date(timeIntervalSince1970: 10), entries: [3: .init(requestStatus: 2, mediaStatus: 4, availableSeasons: [1])])
        prefs.setMyRequestsSnapshot(snap, scope: "s_a")
        #expect(prefs.myRequestsSnapshot(scope: "s_a") == snap)
        #expect(prefs.myRequestsSnapshot(scope: "s_b") == nil)

        let event = MyRequestEvent(requestID: 3, kind: .available, mediaType: .tv, tmdbID: 1, seasons: [1], jellyfinItemID: "j", title: "T", posterPath: nil, date: Date(timeIntervalSince1970: 20))
        prefs.setUnseenMyRequestEvents([event], scope: "s_a")
        #expect(prefs.unseenMyRequestEvents(scope: "s_a") == [event])
        #expect(prefs.unseenMyRequestEvents(scope: "s_b").isEmpty)

        prefs.setMyRequestsSnapshot(nil, scope: "s_a")
        #expect(prefs.myRequestsSnapshot(scope: "s_a") == nil)
    }
}

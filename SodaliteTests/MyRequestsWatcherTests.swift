import Testing
import Foundation
@testable import Sodalite

@MainActor
struct MyRequestsWatcherTests {
    private static func request(
        id: Int, by: Int = 4, type: String = "movie", status: Int, media: Int,
        seasons: [Int] = [], created: String = "1970-01-01T00:00:00.000Z"
    ) -> SeerrRequest {
        let seasonJSON = seasons.enumerated()
            .map { #"{"id":\#($0.offset + 1),"seasonNumber":\#($0.element),"status":2}"# }
            .joined(separator: ",")
        let json = """
        {"id":\(id),"status":\(status),"createdAt":"\(created)","type":"\(type)",
         "media":{"id":\(id),"tmdbId":\(100 + id),"mediaType":"\(type)","status":\(media)},
         "seasons":[\(seasonJSON)],"requestedBy":{"id":\(by),"displayName":"u"}}
        """
        return try! JSONDecoder().decode(SeerrRequest.self, from: Data(json.utf8))
    }

    private func makeWatcher() -> (MyRequestsWatcher, SeerrNotificationPreferences) {
        let prefs = SeerrNotificationPreferences(defaults: UserDefaults(suiteName: "MyRequestsWatcherTests.\(UUID().uuidString)")!)
        let watcher = MyRequestsWatcher(preferences: prefs)
        watcher.scope = { "s_a" }
        watcher.selfSeerrID = { 4 }
        watcher.now = { Date(timeIntervalSince1970: 1_000) }
        watcher.lookupMedia = { _, _ in
            MyRequestsMediaLookup(title: "Title", posterPath: nil, jellyfinItemID: "jf", availableSeasons: [])
        }
        return (watcher, prefs)
    }

    @Test func approvalProducesEnrichedUnseenEventAndCallback() async {
        let (watcher, prefs) = makeWatcher()
        var delivered: [MyRequestEvent] = []
        watcher.onNewEvents = { delivered += $0 }
        watcher.fetchRequests = { _ in [Self.request(id: 1, status: 1, media: 2)] }
        await watcher.refresh()
        #expect(watcher.unseenEvents.isEmpty)

        watcher.fetchRequests = { _ in [Self.request(id: 1, status: 2, media: 3)] }
        await watcher.refresh()
        #expect(watcher.unseenEvents.map(\.kind) == [.approved])
        #expect(watcher.unseenEvents.first?.title == "Title")
        #expect(delivered.count == 1)
        #expect(prefs.unseenMyRequestEvents(scope: "s_a").count == 1)
    }

    @Test func partiallyAvailableShowIsLookedUpForSeasons() async {
        let (watcher, _) = makeWatcher()
        watcher.onNewEvents = { _ in }
        watcher.fetchRequests = { _ in [Self.request(id: 2, type: "tv", status: 2, media: 3, seasons: [1])] }
        await watcher.refresh()
        watcher.fetchRequests = { _ in [Self.request(id: 2, type: "tv", status: 2, media: 4, seasons: [1])] }
        watcher.lookupMedia = { _, _ in
            MyRequestsMediaLookup(title: "Show", posterPath: nil, jellyfinItemID: "jf", availableSeasons: [1, 2])
        }
        await watcher.refresh()
        #expect(watcher.unseenEvents.first?.kind == .available)
        #expect(watcher.unseenEvents.first?.seasons == [1])
    }

    @Test func profileSwitchMidFetchDiscardsResult() async {
        let (watcher, prefs) = makeWatcher()
        let active = ActiveScope()
        watcher.scope = { active.value }
        watcher.onNewEvents = { _ in }
        watcher.fetchRequests = { _ in
            await active.set("s_b")
            return [Self.request(id: 1, status: 1, media: 2)]
        }
        await watcher.refresh()
        #expect(prefs.myRequestsSnapshot(scope: "s_a") == nil)
        #expect(prefs.myRequestsSnapshot(scope: "s_b") == nil)
    }

    @Test func disablingClearsStateAndSkipsFetch() async {
        let (watcher, prefs) = makeWatcher()
        let counter = ActiveScope()
        watcher.onNewEvents = { _ in }
        watcher.fetchRequests = { _ in
            await counter.set("fetched")
            return []
        }
        await watcher.refresh()
        #expect(prefs.myRequestsSnapshot(scope: "s_a") != nil)
        await counter.set(nil)
        watcher.setEnabled(false)
        await watcher.refresh()
        #expect(counter.value == nil)
        #expect(prefs.myRequestsSnapshot(scope: "s_a") == nil)
        #expect(watcher.unseenEvents.isEmpty)
    }

    @Test func markAllSeenClearsPersistedEvents() {
        let (watcher, prefs) = makeWatcher()
        let event = MyRequestEvent(requestID: 1, kind: .declined, mediaType: .movie, tmdbID: 1, seasons: [], jellyfinItemID: nil, title: nil, posterPath: nil, date: .now)
        prefs.setUnseenMyRequestEvents([event], scope: "s_a")
        watcher.reloadForActiveProfile()
        #expect(watcher.unseenEvents.count == 1)
        watcher.markAllSeen()
        #expect(watcher.unseenEvents.isEmpty)
        #expect(prefs.unseenMyRequestEvents(scope: "s_a").isEmpty)
    }

    @Test func showLeavingAvailabilityKeepsItsLandedSeasons() async {
        let (watcher, _) = makeWatcher()
        watcher.onNewEvents = { _ in }
        watcher.fetchRequests = { _ in [Self.request(id: 3, type: "tv", status: 2, media: 3, seasons: [1])] }
        await watcher.refresh()
        watcher.fetchRequests = { _ in [Self.request(id: 3, type: "tv", status: 2, media: 5, seasons: [1])] }
        await watcher.refresh()
        #expect(watcher.unseenEvents.count == 1)
        watcher.markAllSeen()
        // Another user requests a new season: the show drops back to processing, then partial again.
        watcher.fetchRequests = { _ in [Self.request(id: 3, type: "tv", status: 2, media: 3, seasons: [1])] }
        await watcher.refresh()
        watcher.fetchRequests = { _ in [Self.request(id: 3, type: "tv", status: 2, media: 4, seasons: [1])] }
        watcher.lookupMedia = { _, _ in MyRequestsMediaLookup(title: "Show", posterPath: nil, jellyfinItemID: "jf", availableSeasons: [1]) }
        await watcher.refresh()
        #expect(watcher.unseenEvents.isEmpty)
    }

    @Test func refreshRequestedDuringARefreshRunsAgain() async {
        let (watcher, _) = makeWatcher()
        watcher.onNewEvents = { _ in }
        let calls = ActiveScope()
        calls.value = "0"
        watcher.fetchRequests = { _ in
            let n = Int(calls.value ?? "0")! + 1
            calls.set(String(n))
            if n == 1 {
                // A second trigger lands while the first fetch is still out.
                Task { await watcher.refresh() }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(50))
            }
            return []
        }
        await watcher.refresh()
        #expect(calls.value == "2")
    }

}

@MainActor
private final class ActiveScope {
    var value: String? = "s_a"
    func set(_ newValue: String?) { value = newValue }
}

import Foundation
import Observation

struct MyRequestsMediaLookup: Equatable {
    var title: String?
    var posterPath: String?
    var jellyfinItemID: String?
    var availableSeasons: Set<Int>
}

/// Watches the active profile's own Seerr requests and keeps the unseen changes for the badge, the
/// hint panel and (iOS) banners. Fetch and lookups are injected; DependencyContainer wires them.
@Observable
@MainActor
final class MyRequestsWatcher {
    private(set) var unseenEvents: [MyRequestEvent] = []
    private(set) var hasOwnRequests = false

    @ObservationIgnored var scope: @MainActor () -> String? = { nil }
    @ObservationIgnored var selfSeerrID: @MainActor () -> Int? = { nil }
    @ObservationIgnored var fetchRequests: @MainActor (Int) async throws -> [SeerrRequest] = { _ in [] }
    @ObservationIgnored var lookupMedia: @MainActor (SeerrMediaType, Int) async throws -> MyRequestsMediaLookup = { _, _ in
        MyRequestsMediaLookup(availableSeasons: [])
    }
    @ObservationIgnored var onNewEvents: @MainActor ([MyRequestEvent]) async -> Void = { _ in }
    @ObservationIgnored var now: @MainActor () -> Date = { .now }

    @ObservationIgnored private let preferences: SeerrNotificationPreferences
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var lookupCache: [String: MyRequestsMediaLookup] = [:]

    init(preferences: SeerrNotificationPreferences) {
        self.preferences = preferences
    }

    var isEnabled: Bool {
        guard let scope = scope(), selfSeerrID() != nil else { return false }
        return preferences.notifyMyRequests(scope: scope)
    }

    func reloadForActiveProfile() {
        hasOwnRequests = false
        guard isEnabled, let scope = scope() else {
            unseenEvents = []
            return
        }
        unseenEvents = preferences.unseenMyRequestEvents(scope: scope)
    }

    /// A call that lands while one is in flight is not dropped: the running one goes round once more,
    /// so a submit or profile switch during a tick still gets a fresh look.
    func refresh() async {
        guard !isRefreshing else {
            rerunRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            rerunRequested = false
            await refreshOnce()
        } while rerunRequested
    }

    private func refreshOnce() async {
        guard isEnabled, let scope = scope(), let selfID = selfSeerrID() else { return }
        lookupCache = [:]

        guard let requests = try? await fetchRequests(selfID), scope == self.scope() else { return }
        let own = requests.filter { $0.requestedBy?.id == selfID }
        let snapshot = preferences.myRequestsSnapshot(scope: scope)
        var observations: [MyRequestObservation] = []
        for request in own {
            let available = await availableSeasons(for: request, snapshot: snapshot)
            observations.append(MyRequestObservation(request: request, availableSeasons: available))
        }
        guard scope == self.scope() else { return }
        hasOwnRequests = !own.isEmpty

        let result = MyRequestsDiff.apply(snapshot: snapshot, observations: observations, selfID: selfID, now: now())
        preferences.setMyRequestsSnapshot(result.snapshot, scope: scope)
        guard !result.events.isEmpty else { return }

        var enriched: [MyRequestEvent] = []
        for var event in result.events {
            if let tmdbID = event.tmdbID, let lookup = await lookup(event.mediaType, tmdbID) {
                event.title = lookup.title
                event.posterPath = lookup.posterPath
                event.jellyfinItemID = event.jellyfinItemID ?? lookup.jellyfinItemID
            }
            enriched.append(event)
        }
        guard scope == self.scope() else { return }
        unseenEvents = MyRequestEvent.merging(enriched, into: preferences.unseenMyRequestEvents(scope: scope))
        preferences.setUnseenMyRequestEvents(unseenEvents, scope: scope)
        await onNewEvents(enriched)
    }

    func markAllSeen() {
        unseenEvents = []
        if let scope = scope() { preferences.setUnseenMyRequestEvents([], scope: scope) }
    }

    /// Off forgets everything for the profile, so switching back on starts from a fresh baseline
    /// instead of replaying what changed in between.
    func setEnabled(_ enabled: Bool) {
        guard let scope = scope() else { return }
        preferences.setNotifyMyRequests(enabled, scope: scope)
        guard !enabled else { return }
        preferences.setMyRequestsSnapshot(nil, scope: scope)
        preferences.setUnseenMyRequestEvents([], scope: scope)
        unseenEvents = []
    }

    /// Seasons of THIS request that are on the server. The request list carries no per-season media
    /// state, so a partially available show costs one detail lookup until all requested seasons landed.
    private func availableSeasons(for request: SeerrRequest, snapshot: MyRequestsSnapshot?) async -> Set<Int> {
        guard request.type == .tv, let tmdbID = request.media?.tmdbId else { return [] }
        let requested = Set((request.seasons ?? []).map(\.seasonNumber))
        let known = snapshot?.entries[request.id]?.availableSeasons ?? []
        switch request.media?.status {
        case .available:
            return requested
        case .partiallyAvailable:
            if requested.isSubset(of: known) { return known }
            guard let lookup = await lookup(.tv, tmdbID) else { return known }
            return lookup.availableSeasons.intersection(requested)
        default:
            // Dropping back (a new season requested elsewhere, a rescan) does not un-land a season.
            return known
        }
    }

    private func lookup(_ type: SeerrMediaType, _ tmdbID: Int) async -> MyRequestsMediaLookup? {
        let key = "\(type.rawValue)-\(tmdbID)"
        if let cached = lookupCache[key] { return cached }
        guard let fetched = try? await lookupMedia(type, tmdbID) else { return nil }
        lookupCache[key] = fetched
        return fetched
    }
}

import Foundation
import Observation

/// Device-local (UserDefaults) opt-ins + baselines for the Seerr notification features (admin pending queue, the user's own requests);
/// read/write via `DependencyContainer.seerrNotificationPreferences`. Sole owner of its keys.
@Observable
@MainActor
final class SeerrNotificationPreferences {
    private enum Keys {
        static let notifyPendingRequests = "seerr.notifyPendingRequests"
        /// Retired device-global baseline: every Jellyfin profile has its own Seerr session, so one profile's count silenced another profile's notification.
        static let legacyLastSeenPendingCount = "seerr.lastSeenPendingCount"
        static func lastSeenPendingCount(jellyfinServerID: String, jellyfinUserID: String) -> String {
            "seerr.lastSeenPendingCount.\(jellyfinServerID)_\(jellyfinUserID)"
        }
        static func notifyMyRequests(_ scope: String) -> String { "seerr.notifyMyRequests.\(scope)" }
        static func myRequestsSnapshot(_ scope: String) -> String { "seerr.myRequestsSnapshot.\(scope)" }
        static func unseenMyRequests(_ scope: String) -> String { "seerr.unseenMyRequests.\(scope)" }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.notifyPendingRequests = defaults.bool(forKey: Keys.notifyPendingRequests)
        // Deliberately not migrated onto a profile: which one it belonged to was never recorded, and guessing wrong silences that profile. Worst case is one notification about already-pending requests, once.
        defaults.removeObject(forKey: Keys.legacyLastSeenPendingCount)
    }

    var notifyPendingRequests: Bool {
        didSet { defaults.set(notifyPendingRequests, forKey: Keys.notifyPendingRequests) }
    }

    /// Approval count this profile was last notified about, scoped per (Jellyfin server, Jellyfin profile), which is exactly the scope of a Seerr session.
    func lastSeenPendingCount(jellyfinServerID: String, jellyfinUserID: String) -> Int {
        defaults.integer(
            forKey: Keys.lastSeenPendingCount(
                jellyfinServerID: jellyfinServerID,
                jellyfinUserID: jellyfinUserID
            )
        )
    }

    func setLastSeenPendingCount(_ count: Int, jellyfinServerID: String, jellyfinUserID: String) {
        defaults.set(
            count,
            forKey: Keys.lastSeenPendingCount(
                jellyfinServerID: jellyfinServerID,
                jellyfinUserID: jellyfinUserID
            )
        )
    }

    /// Bumped on every toggle write so views reading `notifyMyRequests(scope:)` re-render.
    private(set) var myRequestsRevision = 0

    /// Per profile (`serverID_userID`), on unless switched off.
    func notifyMyRequests(scope: String) -> Bool {
        _ = myRequestsRevision
        return defaults.object(forKey: Keys.notifyMyRequests(scope)) as? Bool ?? true
    }

    func setNotifyMyRequests(_ enabled: Bool, scope: String) {
        defaults.set(enabled, forKey: Keys.notifyMyRequests(scope))
        myRequestsRevision += 1
    }

    func myRequestsSnapshot(scope: String) -> MyRequestsSnapshot? {
        decode(MyRequestsSnapshot.self, Keys.myRequestsSnapshot(scope))
    }

    func setMyRequestsSnapshot(_ snapshot: MyRequestsSnapshot?, scope: String) {
        encode(snapshot, Keys.myRequestsSnapshot(scope))
    }

    func unseenMyRequestEvents(scope: String) -> [MyRequestEvent] {
        decode([MyRequestEvent].self, Keys.unseenMyRequests(scope)) ?? []
    }

    func setUnseenMyRequestEvents(_ events: [MyRequestEvent], scope: String) {
        encode(events.isEmpty ? nil : events, Keys.unseenMyRequests(scope))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

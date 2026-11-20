import Foundation

/// iOS-only BGAppRefreshTask wrapper: polls the pending-approval count in the background and fires a
/// local notification (via PendingRequestsNotifier) when it rose since the last observation.
nonisolated enum PendingRequestsBackgroundRefresh {
    private static let task = BackgroundRefreshTask(identifier: "de.superuser404.Sodalite.pendingRequestsRefresh")
    static var identifier: String { task.identifier }

    /// Register the task handler once at launch. `handle` runs the whole background check on the main
    /// actor (fetch, notify-on-increase, set app-icon badge, persist baseline) and returns whether
    /// notifications are still enabled, so the cycle keeps rescheduling only while opted in.
    static func register(handle: @escaping @MainActor @Sendable () async -> Bool) {
        task.register(handle: handle)
    }

    static func schedule() { task.schedule() }

    static func cancel() { task.cancel() }
}

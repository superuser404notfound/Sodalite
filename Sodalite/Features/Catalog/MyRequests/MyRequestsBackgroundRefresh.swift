#if !os(macOS)
// BGTaskScheduler does not exist on macOS, and the transition it schedules against does not
// either: a Mac app that is not frontmost is still running and still refreshing.
import Foundation

/// Best-effort background poll of the user's own requests (badge on tvOS, banners on iOS).
nonisolated enum MyRequestsBackgroundRefresh {
    private static let task = BackgroundRefreshTask(identifier: "de.superuser404.Sodalite.myRequestsRefresh")
    static var identifier: String { task.identifier }

    static func register(handle: @escaping @MainActor @Sendable () async -> Bool) {
        task.register(handle: handle)
    }

    /// A background launch often has no session restored yet; only a profile that switched the
    /// feature off ends the chain, an unknown one keeps it alive for the next try.
    static func keepScheduling(scope: String?, notifyEnabled: (String) -> Bool) -> Bool {
        guard let scope else { return true }
        return notifyEnabled(scope)
    }

    static func schedule() { task.schedule() }
}
#endif

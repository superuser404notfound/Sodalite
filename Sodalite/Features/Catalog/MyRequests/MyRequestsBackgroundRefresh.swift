import Foundation
import BackgroundTasks

/// Best-effort background poll of the user's own requests (badge on tvOS, banners on iOS).
/// `nonisolated` for the same reason as PendingRequestsBackgroundRefresh: BGTaskScheduler calls the
/// handlers on its own queue, and MainActor-isolated closures would trap there.
nonisolated enum MyRequestsBackgroundRefresh {
    static let identifier = "de.superuser404.Sodalite.myRequestsRefresh"
    private static let earliestInterval: TimeInterval = 30 * 60

    static func register(handle: @escaping @MainActor @Sendable () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            nonisolated(unsafe) let bgTask = task
            let work = Task { @MainActor in
                let keepGoing = await handle()
                if keepGoing { schedule() }
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        try? BGTaskScheduler.shared.submit(request)
    }
}

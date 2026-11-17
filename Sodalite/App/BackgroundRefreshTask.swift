#if !os(macOS)
// BGTaskScheduler does not exist on macOS, where a Mac app that is not frontmost keeps running.
import Foundation
import BackgroundTasks

/// One BGAppRefreshTask registration, shared by the pending-approval poll and the my-requests poll.
/// `nonisolated`: BGTaskScheduler calls the launch and expiration handlers on its own queue, and
/// MainActor-isolated closures would trap in the runtime executor check there (TestFlight crash
/// 2026-07-10). The handler hops to the main actor itself.
nonisolated struct BackgroundRefreshTask: Sendable {
    let identifier: String
    /// iOS throttles refresh anyway; ask for no sooner than ~30 min.
    var earliestInterval: TimeInterval = 30 * 60

    /// `handle` runs on the main actor and returns whether the chain should keep rescheduling.
    func register(handle: @escaping @MainActor @Sendable () async -> Bool) {
        let task = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { bgTask in
            nonisolated(unsafe) let bgTask = bgTask
            let work = Task { @MainActor in
                let keepGoing = await handle()
                if keepGoing { task.schedule() }
                bgTask.setTaskCompleted(success: true)
            }
            bgTask.expirationHandler = { work.cancel() }
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    /// A cold background launch restores the session (and the Seerr connection) on its own schedule,
    /// so a handler waits a bounded moment for what it needs instead of ending the chain on the first
    /// look (PTD-204). Returns the condition's last answer.
    @MainActor
    static func waitFor(
        timeout: Duration = .seconds(20),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition()
    }
}
#endif

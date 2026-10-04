import Foundation

/// A deadline that holds even when the work cannot be cancelled. A task group waits for its
/// slowest child after `cancelAll()`, and `await task.value` on an unstructured task ignores
/// cancellation, so a group-based deadline waits out a dead server's request timeout (Sodalite#85).
nonisolated enum Deadline {
    /// The value of `work`, or nil once `deadline` passes, whichever comes first.
    static func race<T: Sendable>(_ deadline: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let gate = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let worker = Task {
                let value = await work()
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if gate.claim() {
                    worker.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Lets exactly one of two racers resume a continuation.
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            guard !done else { return false }
            done = true
            return true
        }
    }
}

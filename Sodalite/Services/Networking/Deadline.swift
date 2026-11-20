import Foundation

/// A deadline that holds even when the work cannot be cancelled. A task group waits for its
/// slowest child after `cancelAll()`, and `await task.value` on an unstructured task ignores
/// cancellation, so a group-based deadline waits out a dead server's request timeout (Sodalite#85).
nonisolated enum Deadline {
    /// The value of `work`, or nil once `deadline` passes or the calling task is cancelled,
    /// whichever comes first. Either way the worker is cancelled too (audit BRW-206), so a
    /// superseded pass does not keep a secondary server busy for the rest of the deadline.
    static func race<T: Sendable>(_ deadline: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let state = RaceState<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                guard state.install(continuation) else { return }
                let worker = Task {
                    let value = await work()
                    state.finish(value)
                }
                let timer = Task {
                    try? await Task.sleep(for: deadline)
                    state.finish(nil)
                }
                state.attach(worker: worker, timer: timer)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// The shared end of one `Deadline.race`: whoever finishes first resumes the continuation once
/// and cancels the other racers.
nonisolated private final class RaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false
    private var cancelled = false

    /// False when the caller was cancelled before the continuation existed; it is resumed here.
    func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { finished = true } else { self.continuation = continuation }
            return cancelled
        }
        if alreadyCancelled { continuation.resume(returning: nil) }
        return !alreadyCancelled
    }

    func attach(worker: Task<Void, Never>, timer: Task<Void, Never>) {
        let stop = lock.withLock { () -> Bool in
            if finished { return true }
            self.worker = worker
            self.timer = timer
            return false
        }
        if stop { worker.cancel(); timer.cancel() }
    }

    func finish(_ value: T?) {
        let (continuation, worker, timer) = lock.withLock { () -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            defer { self.continuation = nil; self.worker = nil; self.timer = nil }
            return (self.continuation, self.worker, self.timer)
        }
        timer?.cancel()
        if value == nil { worker?.cancel() }
        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.withLock { cancelled = true }
        finish(nil)
    }
}

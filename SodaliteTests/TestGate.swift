import Foundation

/// A phase gate for concurrency tests: `pass()` records an arrival and holds the caller until `open()`,
/// `arrival(_:)` suspends until that many callers have arrived. No timing involved.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resumeNow, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                arrivals += 1
                let ready = watchers.filter { $0.count <= arrivals }.map(\.continuation)
                watchers.removeAll { $0.count <= arrivals }
                if isOpen { return (true, ready) }
                held.append(continuation)
                return (false, ready)
            }
            ready.forEach { $0.resume() }
            if resumeNow { continuation.resume() }
        }
    }

    func arrival(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = lock.withLock { () -> Bool in
                if arrivals >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { held = [] }
            return held
        }
        released.forEach { $0.resume() }
    }
}

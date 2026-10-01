import Testing
import Foundation
@testable import Sodalite

/// The gate exists because Jellyfin keys an open live stream by channel: an open that overtakes our
/// own close of that channel orphans a tuner (or the close lands on the stream that is now playing).
/// So the only thing worth asserting here is the ordering, and that giving up on the WAIT never gives
/// up on the close (#70).
@MainActor
struct LiveTunerGateTests {

    /// Signal a close can park on, so the tests order themselves instead of racing a sleep.
    private nonisolated final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    cont.resume()
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume()
        }
    }

    @Test func settleWithNothingPendingReportsNothingOutstanding() async {
        let gate = LiveTunerGate()
        #expect(gate.pendingCount == 0)
        #expect(await gate.settle(timeout: 5) == 0)
    }

    @Test func settleWaitsForAnOutstandingClose() async {
        let gate = LiveTunerGate()
        let signal = Gate()
        let finished = Locked(false)
        gate.close {
            await signal.wait()
            finished.set(true)
        }
        #expect(gate.pendingCount == 1)

        // Released only once the wait is genuinely in progress; the assertion is the ordering, not a
        // duration, so nothing here depends on how loaded the machine is.
        Task { signal.open() }
        let outstanding = await gate.settle(timeout: 5)

        #expect(finished.value)
        #expect(outstanding == 0)
        #expect(gate.pendingCount == 0)
    }

    @Test func anAbandonedOpenHoldsBackOnlyAnOpenOfTheSameChannel() async {
        let gate = LiveTunerGate()
        let signal = Gate()
        let finished = Locked(false)
        gate.abandonOpen(itemID: "b") {
            await signal.wait()
            finished.set(true)
        }

        #expect(await gate.settle(timeout: 5, opening: "c") == 0)
        #expect(await gate.settle(timeout: 0.05, opening: "b") == 1)

        Task { signal.open() }
        #expect(await gate.settle(timeout: 5, opening: "b") == 0)
        #expect(finished.value)
    }

    @Test func settleGivesUpOnTheWaitButNeverOnTheClose() async {
        let gate = LiveTunerGate()
        let signal = Gate()
        let finished = Locked(false)
        let task = gate.close {
            await signal.wait()
            finished.set(true)
        }

        let outstanding = await gate.settle(timeout: 0.05)
        #expect(outstanding == 1)
        #expect(finished.value == false)

        // The close was never cancelled by the abandoned wait: a cancelled close is a tuner nobody
        // will ever close again.
        #expect(task.isCancelled == false)
        signal.open()
        await task.value
        #expect(finished.value)
    }

    @Test func everyTrackedCloseIsWaitedFor() async {
        let gate = LiveTunerGate()
        let signals = [Gate(), Gate(), Gate()]
        let done = Locked(0)
        for signal in signals {
            gate.close {
                await signal.wait()
                done.increment()
            }
        }
        #expect(gate.pendingCount == 3)

        Task { for signal in signals { signal.open() } }
        let outstanding = await gate.settle(timeout: 5)

        #expect(done.value == 3)
        #expect(outstanding == 0)
    }
}

/// Minimal box so the closures above can report back without an actor hop.
private nonisolated final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    /// Read and write under ONE lock, for the callers that need both.
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

nonisolated extension Locked where Value == Int {
    /// This used to be `set(value + 1)`, which takes the lock twice: three detached closes can each
    /// read the same value and each write the same result, and the count comes out 1 or 2 instead of
    /// 3. Seen twice in one afternoon, both times reported against `LiveTunerGate`, which was not the
    /// thing that was broken.
    func increment() {
        mutate { $0 += 1 }
    }
}

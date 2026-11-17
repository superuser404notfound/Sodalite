import Foundation
import Testing
@testable import Sodalite

struct DeadlineTests {
    @Test func fastWorkWins() async {
        let value = await Deadline.race(.seconds(2)) { 42 }
        #expect(value == 42)
    }

    @Test func slowWorkLosesAtTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        let value: Int? = await Deadline.race(.milliseconds(200)) {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - start < .seconds(2))
    }

    /// The case a task group cannot handle: awaiting an unstructured task ignores cancellation.
    @Test func anUncancellableAwaitStillLoses() async {
        let stubborn = Task<Int?, Never> { try? await Task.sleep(for: .seconds(5)); return 7 }
        let clock = ContinuousClock()
        let start = clock.now
        let value = await Deadline.race(.milliseconds(200)) { await stubborn.value }
        #expect(value == nil)
        #expect(clock.now - start < .seconds(2))
        stubborn.cancel()
    }

    /// BRW-206: a cancelled caller returns at once and its worker sees the cancellation.
    @Test func aCancelledCallerReturnsPromptlyAndCancelsTheWorker() async {
        let sawCancel = Flag()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { () -> Int? in
            await Deadline.race(.seconds(30)) {
                do { try await Task.sleep(for: .seconds(10)) } catch { sawCancel.set() }
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let value = await task.value
        #expect(value == nil)
        #expect(clock.now - start < .seconds(3))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(sawCancel.isSet)
    }

    @Test func aCallerCancelledBeforeTheRaceStartsGetsNil() async {
        let task = Task { () -> Int? in
            while !Task.isCancelled { await Task.yield() }
            return await Deadline.race(.seconds(30)) { try? await Task.sleep(for: .seconds(10)); return 1 }
        }
        task.cancel()
        #expect(await task.value == nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

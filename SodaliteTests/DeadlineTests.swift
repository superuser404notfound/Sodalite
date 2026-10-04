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
}

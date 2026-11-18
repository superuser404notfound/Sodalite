import Testing
import UIKit
@testable import Sodalite

/// Sodalite#123 round 3. A device log showed one "payload stops short" line per logo where the
/// ladder should have written three, so the question is whether the ladder runs to its end at all.
/// It could not be asked before: the loop was a private method on a SwiftUI view.
struct ImageLoadLadderTests {

    private let primary = URL(string: "https://example.invalid/Items/abc/Images/Logo")!

    /// No sleeping in tests; the ladder's delay is a parameter for exactly this reason.
    private func noSleep(_ ms: Int) async throws {}

    @Test("an incomplete payload is asked again, and the second answer is taken")
    func incompletePayloadIsRetried() async {
        var attemptsSeen: [Int] = []
        let result = await ImageLoadLadder.run(
            candidates: [primary, nil],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { url, attempt in
                guard url != nil else { return .noImage }
                attemptsSeen.append(attempt)
                return attempt == 0 ? .incompletePayload : .image(UIImage())
            },
            sleep: noSleep
        )

        #expect(attemptsSeen == [0, 1], "the second attempt has to happen, that is the whole ladder")
        guard case .image = result else {
            Issue.record("a whole image on the second attempt must win")
            return
        }
    }

    @Test("the ladder stops at its limit rather than spinning")
    func incompletePayloadGivesUpAtTheLimit() async {
        var attemptsSeen: [Int] = []
        let result = await ImageLoadLadder.run(
            candidates: [primary],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { _, attempt in
                attemptsSeen.append(attempt)
                return .incompletePayload
            },
            sleep: noSleep
        )

        #expect(attemptsSeen == [0, 1, 2])
        guard case .exhausted(let retryOnActivate) = result else {
            Issue.record("three refusals must exhaust the ladder")
            return
        }
        // An unfinished write heals on its own, so the scene-return retry stays armed.
        #expect(retryOnActivate)
    }

    /// The suspected shape behind round 3: the first attempt is served half a file, the second is
    /// answered with something that is not an image at all. `.noImage` writes no log line of its
    /// own, which is why the device log looked as though nothing had been retried.
    @Test("a noImage answer after an incomplete one ends the ladder without further attempts")
    func noImageAfterIncompleteStops() async {
        var attemptsSeen: [Int] = []
        let result = await ImageLoadLadder.run(
            candidates: [primary],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { _, attempt in
                attemptsSeen.append(attempt)
                return attempt == 0 ? .incompletePayload : .noImage
            },
            sleep: noSleep
        )

        #expect(attemptsSeen == [0, 1], "the retry happens; it is the answer to it that stops things")
        guard case .exhausted(let retryOnActivate) = result else {
            Issue.record("a noImage answer must exhaust rather than hang")
            return
        }
        // An `incomplete` on ANY rung proves the server had the file and was mid-write, which is a
        // state that heals on its own. A later, less informative `noImage` must not erase that: the
        // scene-return retry stays armed, or the text title is permanent for the rest of the session.
        #expect(retryOnActivate, "an incomplete seen earlier must survive a later noImage")
    }

    @Test("a 404 is taken at its word: no second attempt, no scene-return retry")
    func noImageIsFinal() async {
        var attemptsSeen: [Int] = []
        let result = await ImageLoadLadder.run(
            candidates: [primary],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { _, attempt in
                attemptsSeen.append(attempt)
                return .noImage
            },
            sleep: noSleep
        )

        #expect(attemptsSeen == [0], "asking a 404 again reads the same")
        guard case .exhausted(let retryOnActivate) = result else {
            Issue.record("a 404 exhausts immediately")
            return
        }
        #expect(retryOnActivate == false)
    }

    @Test("a dropped connection arms the scene-return retry without spinning now")
    func transientFailureArmsTheSceneRetry() async {
        var attemptsSeen: [Int] = []
        let result = await ImageLoadLadder.run(
            candidates: [primary],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { _, attempt in
                attemptsSeen.append(attempt)
                return .transientFailure
            },
            sleep: noSleep
        )

        // No immediate retry: a lost connection is not fixed 250ms later, it is fixed when the
        // network or the app comes back.
        #expect(attemptsSeen == [0])
        guard case .exhausted(let retryOnActivate) = result else {
            Issue.record("a dropped connection exhausts the immediate ladder")
            return
        }
        #expect(retryOnActivate)
    }

    @Test("cancellation decides nothing, so the caller must not paint a failure")
    func cancellationIsNotAFailure() async {
        struct Cancelled: Error {}
        let result = await ImageLoadLadder.run(
            candidates: [primary],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { _, _ in .incompletePayload },
            sleep: { _ in throw Cancelled() }
        )

        guard case .cancelled = result else {
            Issue.record("a cancelled sleep must report cancellation, not exhaustion")
            return
        }
    }

    @Test("the fallback candidate is tried within the same attempt")
    func fallbackIsTriedBeforeRetrying() async {
        let fallback = URL(string: "https://example.invalid/Items/abc/Images/Backdrop")!
        var order: [String] = []
        let result = await ImageLoadLadder.run(
            candidates: [primary, fallback],
            attemptLimit: 3,
            retryDelayMilliseconds: 250,
            perAttempt: { url, _ in
                order.append(url == self.primary ? "primary" : "fallback")
                return url == self.primary ? .noImage : .image(UIImage())
            },
            sleep: noSleep
        )

        #expect(order == ["primary", "fallback"])
        guard case .image = result else {
            Issue.record("the fallback's image must win")
            return
        }
    }

    @Test("CMP-202: a task cancelled while its request is out ends as cancelled, not as a failure")
    func cancelledMidRequestIsCancelled() async {
        let task = Task { () -> Bool in
            let result = await ImageLoadLadder.run(
                candidates: [primary],
                attemptLimit: 3,
                retryDelayMilliseconds: 250,
                perAttempt: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .noImage
                },
                sleep: noSleep
            )
            if case .cancelled = result { return true }
            return false
        }
        #expect(await task.value)
    }
}

import Foundation


/// What one candidate URL came back as. Not a bool: "nothing arrived", "the connection dropped" and
/// "a whole transfer that carried only the front of an image" each want a different second try.
enum ImageLoadOutcome {
    case image(PlatformImage)
    /// A complete HTTP response whose body is not a complete image. The server is mid-write, so the
    /// next attempt is likely to get the whole thing.
    case incompletePayload
    /// Connection-level. Worth another try when the app or the scene comes back.
    case transientFailure
    /// A non-2xx, undecodable bytes, or a cancelled task. Asking again reads the same.
    case noImage

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    /// Named for the diagnostic log, where the question is which rung answered what.
    var diagnosticName: String {
        switch self {
        case .image: "ok"
        case .incompletePayload: "incomplete"
        case .transientFailure: "transient"
        case .noImage: "noImage"
        }
    }
}

enum ImageLadderResult {
    case image(PlatformImage)
    /// Every rung refused. `retryOnActivate` is true when at least one refusal was the kind that
    /// heals on its own (a dropped connection, a payload still being written).
    case exhausted(retryOnActivate: Bool)
    /// The task was cancelled mid-ladder. The caller must NOT paint a failure: nothing was decided.
    case cancelled
}

/// Sodalite#123. The retry ladder, lifted out of `AsyncCachedImage` so a test can drive it.
///
/// It lived as a private method on a SwiftUI view, which is why two rounds of this bug could only
/// be diagnosed on a device: there was no seam to ask "did the second attempt happen at all".
/// Behaviour is unchanged by the move; `perAttempt` and `sleep` are injected so a test can answer
/// exactly that question without a server.
enum ImageLoadLadder {
    static func run(
        candidates: [URL?],
        attemptLimit: Int,
        retryDelayMilliseconds: Int,
        perAttempt: (URL?, Int) async -> ImageLoadOutcome,
        onOutcome: (Int, URL?, ImageLoadOutcome) -> Void = { _, _, _ in },
        sleep: (Int) async throws -> Void
    ) async -> ImageLadderResult {
        var sawTransientFailure = false

        for attempt in 0..<attemptLimit {
            // NOT reset per attempt (Sodalite#123 round 3). An `incomplete` proves the server had
            // the file and was mid-write, a state that heals by itself. Clearing that at the top of
            // the next rung let a later, less informative `noImage` erase it, and with it the
            // scene-return retry: the text title then stood for the rest of the session, however
            // long the server had been finished. What a rung learns about healability holds.
            var sawIncompletePayload = false

            for candidate in candidates {
                let outcome = await perAttempt(candidate, attempt)
                // A cancelled request comes back as `.noImage`; without this it ended as a failure
                // and the logo title flashed its text fallback (audit CMP-202).
                if Task.isCancelled { return .cancelled }
                onOutcome(attempt, candidate, outcome)
                switch outcome {
                case .image(let image):
                    return .image(image)
                case .incompletePayload:
                    // Both flags: another try right now, and one more when the scene comes back,
                    // because a resize that is still being written finishes on its own.
                    sawIncompletePayload = true
                    sawTransientFailure = true
                case .transientFailure:
                    sawTransientFailure = true
                case .noImage:
                    break
                }
            }

            // Only a payload that stopped in the middle is worth another try right away: the server
            // is still writing the file it just handed us, and it is whole a moment later. A 404 and
            // a body that is not an image read the same on every attempt, and a lost connection is
            // what the scene-return retry is for.
            guard sawIncompletePayload, attempt + 1 < attemptLimit else { break }
            do {
                try await sleep(retryDelayMilliseconds << attempt)
            } catch {
                return .cancelled
            }
        }

        return .exhausted(retryOnActivate: sawTransientFailure)
    }
}

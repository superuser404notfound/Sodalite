import Foundation

/// Serializes our live-stream opens against our own pending closes, process-wide.
///
/// Jellyfin keys an open live stream by CHANNEL, not by tuner instance. `LiveTvMediaSourceProvider`
/// sets `LiveStreamId = md5(serviceTypeName) + "_" + MediaSource.Id`, and a tuner host's
/// `MediaSource.Id` is derived from the profile, the channel and the tuner URL
/// (`HdHomerunHost.GetMediaSource`: `native_<md5 channel>_<md5 url>`), so it is the same string for
/// every tune of that channel. `MediaSourceManager.OpenLiveStreamInternal` then does a plain
/// `_openStreams[mediaSource.LiveStreamId] = liveStream`, and `CloseLiveStream` looks the id up in
/// that same dictionary.
///
/// Two consequences, and both are ours to avoid:
///
/// 1. An open that lands while a close for the same channel is still in flight REPLACES the entry.
///    The stream it replaced keeps ingesting into its temp file, keeps its tuner, and can never be
///    closed again: nothing references it any more. That is the tuner that "was released" according
///    to us and is still busy according to the tuner.
/// 2. If the close lands after the new open instead, it names the id of the stream that is now
///    playing and closes THAT one.
///
/// Both requests also contend for the server's own `_liveStreamLocker`, and an open holds it for the
/// whole tuner handshake, so a close issued a moment earlier can still be answered a few seconds
/// later. Firing a close and opening the next stream "right after" is therefore not an ordering.
/// Waiting for our own closes to be answered is (#70).
@MainActor
final class LiveTunerGate {
    static let shared = LiveTunerGate()

    private var pending: [UUID: Task<Void, Never>] = [:]
    private var abandonedOpens: [UUID: (itemID: String, task: Task<Void, Never>)] = [:]

    /// Run a tuner close as a tracked, detached task. Detached so a slow server cannot stall a
    /// teardown, tracked so the next open can wait for it.
    @discardableResult
    func close(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let gate = self
        let task = Task.detached {
            await work()
            await MainActor.run { gate.deregister(id) }
        }
        // Inserted without an await, so the deregistration above (which has to hop back onto this
        // actor) cannot run before the insert and leave a task pending forever.
        pending[id] = task
        return task
    }

    private func deregister(_ id: UUID) {
        pending[id] = nil
    }

    /// Track an open whose tune was superseded while Jellyfin was still answering it. The request runs
    /// on, since cancelling it loses a tuner the server may still open, and `work` closes whatever it
    /// answers with. A later open of the SAME item waits for it like for a close: both name the channel.
    func abandonOpen(itemID: String, _ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let gate = self
        let task = Task.detached {
            await work()
            await MainActor.run { gate.abandonedOpens[id] = nil }
        }
        abandonedOpens[id] = (itemID, task)
    }

    /// How many closes are still unanswered. Test seam.
    var pendingCount: Int { pending.count }

    private func abandonedOpenCount(_ itemID: String?) -> Int {
        abandonedOpens.values.filter { $0.itemID == itemID }.count
    }

    private func unsettled(opening itemID: String?) -> Int {
        pending.count + abandonedOpenCount(itemID)
    }

    /// Wait for every close we have fired to be answered, bounded. Returns the number still
    /// unanswered when the wait ended, which is 0 on the normal path (a zap gives a close seconds to
    /// land before the next channel is picked) and non-zero only when the server is sitting on one.
    ///
    /// Polled rather than raced against a sleeping sibling task, because `await task.value` does not
    /// observe cancellation: a task group whose sleeper wins the race still waits for the other child
    /// on the way out, so the bound would not have been a bound at all and one hung close would have
    /// stalled every later tune. Giving up on the WAIT never cancels the close itself, since a
    /// cancelled close is a tuner nobody will ever close again.
    @discardableResult
    ///
    /// An abandoned open of `itemID` gets its own bound, `abandonedOpenTimeout`, which a caller sets to
    /// how long that answer can take: the close that follows it names the channel too.
    func settle(
        timeout: TimeInterval, opening itemID: String? = nil, abandonedOpenTimeout: TimeInterval = 0
    ) async -> Int {
        guard unsettled(opening: itemID) > 0 else { return 0 }
        let start = Date()
        let closeDeadline = start.addingTimeInterval(max(0, timeout))
        let openDeadline = start.addingTimeInterval(max(timeout, abandonedOpenTimeout))
        func waiting() -> Bool {
            let now = Date()
            return (!pending.isEmpty && now < closeDeadline)
                || (abandonedOpenCount(itemID) > 0 && now < openDeadline)
        }
        while waiting() {
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                break
            }
        }
        return unsettled(opening: itemID)
    }
}

/// How a tune's wait for its PlaybackInfo ended.
enum TunerOpenOutcome: Sendable {
    case answered(Result<PlaybackInfoResponse, Error>)
    case superseded
}

/// Resumes one continuation with whichever outcome arrives first, including one that arrives before
/// the continuation does (a cancellation handler runs at once when the caller is already cancelled).
nonisolated final class FirstOutcome: @unchecked Sendable {
    private enum State {
        case waiting
        case armed(CheckedContinuation<TunerOpenOutcome, Never>)
        case early(TunerOpenOutcome)
        case done
    }

    private let lock = NSLock()
    private var state = State.waiting

    func arm(_ continuation: CheckedContinuation<TunerOpenOutcome, Never>) {
        let early: TunerOpenOutcome? = lock.withLock {
            if case .early(let outcome) = state {
                state = .done
                return outcome
            }
            state = .armed(continuation)
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func finish(_ outcome: TunerOpenOutcome) {
        let armed: CheckedContinuation<TunerOpenOutcome, Never>? = lock.withLock {
            switch state {
            case .waiting:
                state = .early(outcome)
                return nil
            case .armed(let continuation):
                state = .done
                return continuation
            case .early, .done:
                return nil
            }
        }
        armed?.resume(returning: outcome)
    }
}

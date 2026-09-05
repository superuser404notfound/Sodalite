import Foundation
import Network

/// Whether a failure to reach a LAN address is the device withholding Local Network access rather
/// than a network fault (Sodalite#92).
///
/// The symptom is misleading by construction. A denied app sees `NSURLErrorDomain -1009`, "The
/// Internet connection appears to be offline", for a server the same device opens fine in Safari,
/// because Safari is exempt from the permission. Reporters then check Wi-Fi, restart the router and
/// re-enter the address, since nothing in that sentence points at Settings > Privacy & Security >
/// Local Network. The fix is five seconds long once you know; the sentence is what hides it.
///
/// Two stages, and only the second one may accuse the device. `couldBeDenial` is a pure pre-filter
/// over the error and the address, so a genuinely offline device or a dead remote server never pays
/// for a probe. `isDenied` then asks the system rather than guessing: a connection scoped to that
/// LAN endpoint carries a path whose `unsatisfiedReason` is the system's own word for this state.
/// A classifier that stopped at the pre-filter would call an offline phone "denied", which is a
/// worse sentence than the one it replaces, so the pre-filter alone never sets the verdict.
///
/// Only `HTTPClient` on iOS and iPadOS ever asks. tvOS 26.6 has no Local Network privacy: its
/// Settings > General > Privacy & Security lists Location, Tracking, Photos, Bluetooth, Microphone,
/// Camera, Apple Home and Media, with no Local Network row, and TVSettings.app carries no such
/// string either (measured 2026-08-29). There, the pre-filter could only ever be a false alarm, and
/// every false alarm would cost a two second probe in front of the real error. The type stays
/// compiled on both platforms so the tests that pin the pre-filter run in the tvOS test target,
/// which is the only target this project has.
nonisolated enum LocalNetworkAccess {

    /// Raised the first time a probe returns a denial, so the network layer can surface an app-level
    /// state without knowing what an `AppState` is. `SodaliteApp` installs it, the same way it
    /// installs the engine's log handler.
    @MainActor static var onDenial: (@MainActor @Sendable () -> Void)?

    // MARK: Pre-filter

    /// Cheap gate in front of the probe: true only where a denial could explain what was seen.
    ///
    /// Both halves earn their place. The address half keeps a dead remote server out, since the
    /// permission governs the LAN and nothing else, and less obviously keeps loopback out:
    /// 127.0.0.1 needs no permission, though `ServerURLClassifier` counts it as internal for its own
    /// purpose. The error half keeps every ordinary refusal and timeout out. What reaches the probe
    /// is then only the exact sentence a denial produces.
    static func couldBeDenial(_ error: Error, url: URL) -> Bool {
        isGoverned(url) && carriesDenialSignature(error)
    }

    /// True where Local Network privacy has any say over reaching this address at all.
    static func isGoverned(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !isLoopback(host) else { return false }
        return ServerURLClassifier.isInternal(url)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        return bare == "localhost" || bare == "::1" || bare.hasPrefix("127.")
    }

    /// The error sentence a denial produces, looked for through the underlying-error chain.
    ///
    /// `-1009` is what URLSession reports, and `ENETDOWN` is the same verdict seen one layer down.
    /// Either alone is only a suspicion, which is why this answers `couldBeDenial` and not the
    /// question itself.
    private static func carriesDenialSignature(_ error: Error, depth: Int = 0) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENETDOWN) {
            return true
        }
        guard depth < 4 else { return false }
        return nsError.underlyingErrors.contains { carriesDenialSignature($0, depth: depth + 1) }
    }

    // MARK: Probe

    /// Asks the system whether this address is unreachable because the app may not use the local
    /// network. Answers false for anything it cannot establish, so the generic error stands rather
    /// than a wrong accusation replacing it.
    ///
    /// Not measured: a server addressed by a `.local` name. Resolving one needs mDNS, which the same
    /// permission governs, so the connection may fail on the name before it ever has a path to read
    /// a reason off. That reads as "nothing established" here and leaves the old generic error in
    /// place, which is the status quo for those setups rather than a regression, but it is a gap
    /// somebody with such a server could close by measuring what the reading actually is.
    static func isDenied(for url: URL) async -> Bool {
        guard isGoverned(url), let host = url.host(), let port = port(for: url) else { return false }
        guard isAttachedToALocalNetwork(host: host, port: port) else { return false }
        let denied = await LocalNetworkProber.shared.isDenied(host: host, port: port)
        guard denied else { return false }
        LogTap.shared.note("[network] local network access denied by this device for \(host):\(port)")
        raiseIfNothingIsGettingThrough(url)
        return true
    }

    /// A denial cannot be true where there is no local network to be kept off (Sodalite#122).
    ///
    /// The permission governs access to a LAN this device is attached to. With Wi-Fi off and only
    /// cellular carrying the path, there is no such LAN, and every reason the probe can report
    /// becomes an answer to a different question. Measured on an iPhone 17 Pro on 5G against a
    /// LAN-only server: the probe said denied and the app told its owner to switch on a permission
    /// that was already on, which is a worse sentence than the vague one #92 replaced. The truth
    /// there is that the server is not on the network this phone is currently attached to, and
    /// `ServerReachability` is what says so.
    ///
    /// This is a coherence check on the accusation, not a prediction about reachability, which is
    /// why it is safe where a "cellular means unreachable" rule would not be: it can only ever
    /// withdraw a claim the app was about to make about the DEVICE.
    ///
    /// Fails open on an unknown path. The monitor's first callback may not have landed yet, and a
    /// missing reading is not evidence of anything.
    private static func isAttachedToALocalNetwork(host: String, port: UInt16) -> Bool {
        guard let reading = NetworkPathSnapshot.shared.current else { return true }
        guard !reading.isAttachedToALocalNetwork else { return true }
        LogTap.shared.note(
            "[network] not accusing this device over \(host):\(port): no local network to be denied "
            + "(satisfied=\(reading.isSatisfied) usesLocal=\(reading.usesLocalInterface) "
            + "hasLocal=\(reading.hasLocalInterface))"
        )
        return false
    }

    /// A denial is true about the address it was measured on, and the error case says so. Whether it
    /// is true about the APP is a second question, and the answer is no more often than it looks: a
    /// LAN Seerr can be denied beside a Jellyfin on a public name, and the internal slot of a
    /// dual-URL server can be denied while the external slot serves the whole session. Covering
    /// either of those with a full-screen "nothing works" is a wrong sentence replacing a right one.
    ///
    /// So the app-level state is raised only when nothing has been getting through, which is a fact
    /// the app already holds rather than an inference about the user's network.
    private static func raiseIfNothingIsGettingThrough(_ url: URL) {
        guard !SuccessWitness.shared.sawSuccess(within: cutOffWindow) else {
            LogTap.shared.note("[network] denial stands for \(url.host() ?? "?") but other requests are answering, no app-level state raised")
            return
        }
        Task { @MainActor in onDenial?() }
        Task { @MainActor in lastDeniedURL = url }
    }

    /// How long the app must have gone without a single successful response before a denial is
    /// allowed to speak for the whole app. Long enough to outlast one server's slow round trip,
    /// short enough that a cut-off launch does not sit on the wrong error while it elapses (a launch
    /// that never succeeds has no witness at all and raises the state at once).
    private static let cutOffWindow: Duration = .seconds(20)

    /// The address the standing denial was measured against, so a retry re-asks that same question
    /// instead of guessing at one.
    @MainActor private(set) static var lastDeniedURL: URL?

    /// Records that some request, to some backend, came back. Called on every success, so it must
    /// stay as cheap as it looks.
    static func noteReachableServer() {
        SuccessWitness.shared.record()
    }

    /// Re-asks the system about the address the standing denial was measured on. True while it
    /// stands; false both when the permission is back and when there is nothing to re-ask.
    static func stillDenied() async -> Bool {
        guard let url = await MainActor.run(body: { lastDeniedURL }) else { return false }
        await forgetVerdict()
        guard isGoverned(url), let host = url.host(), let port = port(for: url) else { return false }
        return await LocalNetworkProber.shared.isDenied(host: host, port: port)
    }

    /// Drops the remembered verdict, so the next failure asks the system again. The app calls this
    /// when it comes forward: returning from Settings is exactly how the answer changes.
    static func forgetVerdict() async {
        await LocalNetworkProber.shared.forgetVerdict()
    }

    /// True where this connection error is the system saying the local network is off limits.
    /// Split out from the probe so the reading is testable without a live connection.
    static func namesDenial(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .ENETDOWN { return true }
        return false
    }

    private static func port(for url: URL) -> UInt16? {
        if let port = url.port, let value = UInt16(exactly: port) { return value }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Runs the probe at most once per address at a time and remembers its verdict briefly.
///
/// Home's first load fans out 60 to 90 requests. Without this, a denied device would answer one
/// device-wide question 60 to 90 times, each with its own connection.
private actor LocalNetworkProber {
    static let shared = LocalNetworkProber()

    /// Verdict lifetime. Long enough that one Home fan-out asks once, short enough that it cannot
    /// outlive the screen it was shown on. Returning from Settings clears it outright.
    private static let ttl: Duration = .seconds(10)

    /// How long a probe waits for the endpoint to say anything.
    ///
    /// A denial is immediate: the system answers it without touching the network. This bound covers
    /// the other case, where the permission is still undetermined and the prompt is on screen
    /// unanswered, and that case must NOT be reported as a denial. Timing out therefore means
    /// "nothing established", never "denied".
    private static let probeTimeout: TimeInterval = 2

    private var verdicts: [String: (denied: Bool, at: ContinuousClock.Instant)] = [:]
    private var running: [String: Task<Bool, Never>] = [:]

    func isDenied(host: String, port: UInt16) async -> Bool {
        let key = "\(host):\(port)"
        if let cached = verdicts[key], cached.at.duration(to: .now) < Self.ttl {
            return cached.denied
        }
        // Awaiting a running probe ignores this caller's cancellation, which is tolerable only
        // because the probe is bounded above and its answer describes the device, not this request.
        if let inFlight = running[key] {
            return await inFlight.value
        }
        let task = Task<Bool, Never> { await Self.probe(host: host, port: port) }
        running[key] = task
        let denied = await task.value
        running[key] = nil
        verdicts[key] = (denied, .now)
        return denied
    }

    func forgetVerdict() {
        verdicts.removeAll()
    }

    private static func probe(host: String, port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "de.superuser404.Sodalite.localNetworkProbe")

        let denied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = OneShotAnswer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    answer.resume(verdict(path: connection.currentPath, error: error))
                case .ready, .cancelled:
                    answer.resume(false)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + probeTimeout) { answer.resume(false) }
        }

        connection.cancel()
        return denied
    }

    /// The two readings that name a denial, in the order of how much they claim.
    ///
    /// `unsatisfiedReason` is the system's own name for this state and needs no interpretation.
    /// `ENETDOWN` is the same verdict seen from the BSD layer, kept because the reason is carried
    /// only by a path scoped to the endpoint, and a connection that failed before it had one has no
    /// such reading. Neither is a guess about a healthy network: a host that is merely down answers
    /// `ECONNREFUSED` or falls silent, and the timeout above covers silence.
    private static func verdict(path: NWPath?, error: NWError) -> Bool {
        if let path, path.status == .unsatisfied, path.unsatisfiedReason == .localNetworkDenied {
            return true
        }
        return LocalNetworkAccess.namesDenial(error)
    }
}

/// One-shot continuation. The connection's state handler and the timeout both race to answer, and
/// exactly one of them may.
private nonisolated final class OneShotAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Instant of the most recent successful response, from any request to any backend.
///
/// Read on the failure path only, written on every success, which is why it is a lock and not an
/// actor: a hop per response would put a suspension in front of every row Home loads to answer a
/// question almost nobody asks.
private nonisolated final class SuccessWitness: @unchecked Sendable {
    static let shared = SuccessWitness()

    private let lock = NSLock()
    private var last: ContinuousClock.Instant?

    func record() {
        lock.lock()
        last = .now
        lock.unlock()
    }

    func sawSuccess(within window: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last else { return false }
        return last.duration(to: .now) < window
    }
}

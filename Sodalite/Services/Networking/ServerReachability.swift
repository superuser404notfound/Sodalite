import Foundation

/// What the app knows about whether the active Jellyfin server answers from where the device is
/// standing right now (Sodalite#122).
///
/// One verdict for the whole app, produced where the facts already are. `ServerRouteResolver`
/// probes an unauthenticated status endpoint with a hard two second cap on every session start,
/// foreground and path change; before this the probe learned the answer and had nowhere to put it,
/// so every screen rediscovered the same fact one thirty second request timeout at a time. On a
/// LAN-only server off the home network that took Home between one and three minutes, spent under a
/// bare spinner, and the sentence at the end of it was the wrong lead anyway.
///
/// The verdict is a measurement, never a prediction. That is what keeps it correct on the cases a
/// path-and-interface heuristic gets wrong: a Tailscale or WireGuard tunnel carrying RFC1918 on
/// cellular simply answers, an `.local` name resolves exactly the way the real request resolves it,
/// and a foreign Wi-Fi where the address might legitimately exist is settled by asking rather than
/// by guessing. It also never changes routing. An unreachable address stays the address; only what
/// the app is willing to say about it changes.
nonisolated enum ServerReachability: Equatable, Sendable {
    /// Nothing measured yet this session.
    case unknown

    /// The address answered.
    case reachable

    /// The device has no usable network path at all. Nothing about the server is knowable from
    /// here, and no advice about addresses applies.
    case noNetwork

    /// The address did not answer, it is a LAN address, and this server has no remote slot to fall
    /// back to. The one failure with a fix the user can act on.
    case offNetwork

    /// The address did not answer, for a reason the app cannot narrow any further.
    case unreachable

    var isFailure: Bool {
        switch self {
        case .noNetwork, .offNetwork, .unreachable: true
        case .unknown, .reachable: false
        }
    }
}

extension ServerReachability {
    /// Turn one probe result into the verdict.
    ///
    /// Pure and nonisolated so the matrix behind it is pinned by tests rather than by a device
    /// round trip, the way `LocalNetworkAccess`'s pre-filter is.
    ///
    /// `pathIsSatisfied` is nil before the monitor's first callback, and a nil must not be read as
    /// "offline": an unknown path is a reason to stay vague, not a reason to accuse the device.
    ///
    /// The LAN test goes through `LocalNetworkAccess.isGoverned` rather than through
    /// `ServerURLClassifier.isInternal` directly, because the two differ on exactly one address and
    /// it matters here: 127.0.0.1 classifies as internal, and a loopback server that stopped
    /// answering has nothing to do with which network the device is on.
    static func classify(
        probedURL: URL,
        answered: Bool,
        hasAlternateSlot: Bool,
        pathIsSatisfied: Bool?
    ) -> ServerReachability {
        if answered { return .reachable }
        if pathIsSatisfied == false { return .noNetwork }
        // A server that already carries a remote address is not missing one, so the advice that
        // makes `.offNetwork` worth its own case would be wrong.
        if !hasAlternateSlot, LocalNetworkAccess.isGoverned(probedURL) { return .offNetwork }
        return .unreachable
    }
}

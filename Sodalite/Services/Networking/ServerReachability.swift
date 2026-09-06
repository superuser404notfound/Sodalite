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
    ///
    /// `isAttachedToALocalNetwork` is what keeps `.offNetwork` from over-claiming, and it is the
    /// same reading the Sodalite#92 denial check takes. A device sitting ON a local network whose
    /// LAN server does not answer is not a device on the wrong network: its server is off, or
    /// asleep, or on another subnet. Saying "only reachable on your home network" there is false,
    /// and the address advice under it is worse than useless, since no second URL brings a
    /// powered-down server back. On an Apple TV, which never leaves its network, that was every
    /// outage it can have. Unknown reads as a reason to stay vague, the way an unknown path does:
    /// `.offNetwork` is a claim about where the device is standing, and a claim needs a reading.
    static func classify(
        probedURL: URL,
        answered: Bool,
        hasAlternateSlot: Bool,
        pathIsSatisfied: Bool?,
        isAttachedToALocalNetwork: Bool?
    ) -> ServerReachability {
        if answered { return .reachable }
        if pathIsSatisfied == false { return .noNetwork }
        // A server that already carries a remote address is not missing one, so the advice that
        // makes `.offNetwork` worth its own case would be wrong.
        if !hasAlternateSlot,
           isAttachedToALocalNetwork == false,
           LocalNetworkAccess.isGoverned(probedURL) {
            return .offNetwork
        }
        return .unreachable
    }

    /// What a content screen shows instead of its content, or nil to keep loading and keep whatever
    /// it already has.
    ///
    /// Shared rather than decided per screen. Home and the library grid ask one question, and the
    /// grid answering it on its own is how it went on rendering "Couldn't reach your server. Check
    /// the connection and try again." for a release after Home stopped: off Wi-Fi that sentence is
    /// not merely vague, it sends the reader to restart a router they are nowhere near.
    ///
    /// Two sources, and the fast one is the point of Sodalite#122. The route probe settles the
    /// question about two seconds into launch; a fan-out needs thirty seconds to three minutes to
    /// prove the same thing one request timeout at a time. So the verdict speaks as soon as it
    /// lands, and a screen that can only know THAT its load failed still gets to say why.
    ///
    /// Only while nothing has painted. Content that arrived anyway outranks the verdict: the probe
    /// asked one endpoint, and a server that is demonstrably answering is answering. That is what
    /// keeps a dual-slot server on a working external route from ever seeing the screen.
    func blockingState(hasContent: Bool, loadFailedEntirely: Bool) -> ServerReachability? {
        guard !hasContent else { return nil }
        if isFailure { return self }
        // No verdict against the server, or none yet: only the fan-out draining empty may speak, and
        // it cannot say why.
        return loadFailedEntirely ? .unreachable : nil
    }

    /// What the tab's status strip says over content that is already on screen, or nil to stay quiet
    /// (Sodalite#126).
    ///
    /// The complement of `blockingState`, and the pair is why the verdict is now consumed after the
    /// first load instead of only during it. Where nothing painted, the full screen speaks and this
    /// keeps out from under it; where something did, the strip is the only one that still can say
    /// anything, because content that arrived outranks the probe and must not be replaced by an
    /// apology for something the reader can see working.
    func bannerState(fullScreenIsShowing: Bool) -> ServerReachability? {
        guard !fullScreenIsShowing, isFailure else { return nil }
        return self
    }
}

import Foundation

/// Holds a client's credentials back from a LAN address until that address has proved it is the
/// server the session belongs to (audit NET-201, NET-202).
///
/// A session starts on the last address that worked, and on another network the home LAN address
/// belongs to somebody else: a friend's Jellyfin, a router page, a rogue access point. The route
/// probe already refused to CHOOSE such an address (NETWORK-2), but every launch, switch and Combine
/// secondary pointed the client there first and sent the token before the probe had run. Whatever
/// answered 401 was then read as the server's verdict: the stored password went to it, and the
/// profile was dropped on every device.
///
/// Only LAN addresses wait. A public address means the same host from every network, so it has
/// nothing to prove here and costs nothing extra. At home the internal probe answers in tens of
/// milliseconds; away from home the optimistic LAN address would have failed anyway.
///
/// One gate per client. `reset()` starts an epoch whenever who answers at an address may have
/// changed (a session or network change, a return from the background); the route resolve then
/// `record`s each probe as it lands and `settle`s the epoch when it is done. A request to an address
/// that never proved itself is refused once the epoch settled.
///
/// The proof is the identity answer alone, never readiness or the route probe's two second cap: a
/// slow, booting or proxied-5xx server is still this server, and content that arrives outranks the
/// verdict (Sodalite#199, audit review R-ROUTE-1). Only an answer naming another server takes a
/// proof back; silence does not.
@MainActor
final class RouteGate {
    /// Off for clients over a test double: they reach no network, so there is nothing to prove.
    var isEnforced: Bool

    /// Moves on every `reset()`. A probe or settle from an older epoch is about an address that may
    /// belong to someone else by now, so it is dropped.
    private(set) var epoch: UInt64 = 0
    private var verified: Set<URL> = []
    /// Starts settled so a client nobody resolves (signed out, no server) refuses instead of
    /// waiting forever.
    private(set) var isSettled = true
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The error each refused address gets this epoch. One question per address, shared by every
    /// request a settle releases at once (audit review R-ROUTE-26).
    private var refusals: [URL: Task<APIError, Never>] = [:]

    init(isEnforced: Bool) {
        self.isEnforced = isEnforced
    }

    /// Addresses whose owner depends on the network the device is on. Loopback is this device.
    nonisolated static func needsProof(_ url: URL) -> Bool {
        LocalNetworkAccess.isGoverned(url)
    }

    /// May credentials go to `url` right now, without waiting?
    func allows(_ url: URL) -> Bool {
        !isEnforced || !Self.needsProof(url) || verified.contains(url)
    }

    /// Whether `url` answered as this server in the current epoch. Unlike `allows`, a public
    /// address counts only once it did.
    func hasVerified(_ url: URL) -> Bool {
        verified.contains(url)
    }

    /// What was proved says nothing any more. A resolve has to follow, or waiting requests sit
    /// until the next one.
    func reset() {
        epoch &+= 1
        verified = []
        refusals = [:]
        isSettled = false
        wakeAll()
    }

    /// One identity answer for `url`.
    func record(_ url: URL, identity: ServerProbe.Identity, epoch: UInt64) {
        guard epoch == self.epoch else { return }
        switch identity {
        case .matches: verified.insert(url)
        case .otherServer: verified.remove(url)
        case .noAnswer: return
        }
        wakeAll()
    }

    /// The resolve for this epoch is done; what it did not prove stays unproved.
    func settle(epoch: UInt64) {
        guard epoch == self.epoch else { return }
        isSettled = true
        wakeAll()
    }

    /// The address to send to, read again after every wait because the resolve may move it.
    /// Throws `.serverUnreachable` for a LAN address that did not prove itself.
    func admit(_ currentURL: () -> URL?) async throws -> URL {
        while true {
            try Task.checkCancellation()
            guard let url = currentURL() else { throw APIError.invalidURL }
            if allows(url) { return url }
            if isSettled { throw await refusal(for: url) }
            await waitForChange()
        }
    }

    /// The same sentence a request that reached the transport would have produced. On iOS a LAN
    /// address the device withholds Local Network access from is the usual reason nothing proved
    /// itself, and only this question raises the screen that says so (Sodalite#92, audit review
    /// R-ROUTE-2). Asked once per address and epoch; tvOS has no such permission.
    private func refusal(for url: URL) async -> APIError {
        if let asked = refusals[url] { return await asked.value }
        let asking = Task<APIError, Never> {
            #if os(iOS)
            return await LocalNetworkAccess.isDenied(for: url) ? .localNetworkDenied : .serverUnreachable
            #else
            return .serverUnreachable
            #endif
        }
        refusals[url] = asking
        return await asking.value
    }

    /// Returns once the current epoch's resolve has finished.
    func waitUntilSettled() async {
        while !isSettled, !Task.isCancelled {
            await waitForChange()
        }
    }

    private func waitForChange() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func wakeAll() {
        let woken = waiters
        waiters = [:]
        for continuation in woken.values { continuation.resume() }
    }
}

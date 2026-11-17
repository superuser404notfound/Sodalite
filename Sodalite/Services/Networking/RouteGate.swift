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
/// changed (a session or network change); the route resolve then `record`s each probe as it lands
/// and `settle`s the epoch when it is done. A request admitted after settling to an address that
/// never proved itself is refused as unreachable, which is what the verdict says anyway.
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
        isSettled = false
        wakeAll()
    }

    /// One probe's answer. A failed one also takes back an earlier proof: the same address now
    /// answers as somebody else, or not at all.
    func record(_ url: URL, answered: Bool, epoch: UInt64) {
        guard epoch == self.epoch else { return }
        if answered {
            verified.insert(url)
        } else {
            verified.remove(url)
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
            if isSettled { throw APIError.serverUnreachable }
            await waitForChange()
        }
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

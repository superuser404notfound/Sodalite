import Foundation

/// A certificate the user has been asked about and not yet answered for.
struct PendingCertificateTrust: Identifiable, Equatable {
    let host: String
    /// Nil when the handshake failed before a chain was offered, so there is nothing to compare.
    let fingerprint: String?
    /// This host was trusted before, with a different certificate. A first acceptance and a change
    /// are not the same question: one of them can be an attack, and they must not read alike.
    let isReplacingAPin: Bool

    var id: String { host + (fingerprint ?? "") }
}

/// The pin-and-retry step both connect screens share (ASD-R203): what to ask when a handshake is
/// refused, and what to store when the user says yes. What "retry" means stays with the caller.
enum CertificateTrustPrompt {
    static func pending(host: String, fingerprint: String?, trustStore: ServerTrustStore) -> PendingCertificateTrust {
        PendingCertificateTrust(host: host, fingerprint: fingerprint,
                                isReplacingAPin: trustStore.pinnedFingerprint(forHost: host) != nil)
    }

    /// True when a pin was stored and the caller should ask the server again. Without a fingerprint
    /// there is nothing to compare, so nothing is pinned.
    static func pin(_ pending: PendingCertificateTrust?, trustStore: ServerTrustStore) -> Bool {
        guard let pending, let fingerprint = pending.fingerprint else { return false }
        trustStore.pin(fingerprint, forHost: pending.host)
        return true
    }
}

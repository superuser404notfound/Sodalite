import Foundation
import Observation

/// Single source of truth for the count of Jellyseerr requests pending approval (admin only).
/// The Catalog tab badge and the background refresh handler both read this. Eligibility and the
/// actual network fetch are injected closures so the monitor is decoupled from AppState / services
/// and trivially testable; DependencyContainer wires them in `wirePendingRequestsMonitor()`.
@Observable
@MainActor
final class PendingRequestsMonitor {
    private var storedCount: Int?
    /// Whose count `storedCount` is. A count only reads as a count while that is still the active
    /// identity, so a switch to another Seerr profile never shows the previous admin's badge (CAT-204).
    private var countIdentity: String?

    var pendingApprovalCount: Int? {
        guard let storedCount, countIdentity == identity() else { return nil }
        return storedCount
    }

    /// True when the active Seerr user may manage requests and is connected.
    @ObservationIgnored var isEligible: @MainActor () -> Bool = { false }
    /// The active Seerr identity (profile plus Seerr user), nil when there is none.
    @ObservationIgnored var identity: @MainActor () -> String? = { nil }
    /// Fetches the current pending-approval count from Jellyseerr.
    @ObservationIgnored var fetchPendingCount: () async throws -> Int = { 0 }

    init() {}

    /// Fetch + publish the pending count. No-op unless eligible. On failure the prior value stands. Not eligible clears it.
    /// This owns only the live count (the Catalog tab badge). The notification baseline
    /// (`lastSeenPendingCount`) is the notification path's concern, not the monitor's.
    func refresh() async {
        guard isEligible() else {
            reset()
            return
        }
        let asked = identity()
        do {
            let count = try await fetchPendingCount()
            // The answer belongs to whoever asked; a switch while it was in flight drops it.
            guard identity() == asked else { return }
            storedCount = count
            countIdentity = asked
        } catch {
            // Keep the previous value; never clobber to nil/0 on a transient failure.
        }
    }

    func reset() {
        storedCount = nil
        countIdentity = nil
    }

    /// Notify only when the count genuinely rose since the last observation.
    static func shouldNotify(current: Int, lastSeen: Int) -> Bool {
        current > lastSeen
    }
}

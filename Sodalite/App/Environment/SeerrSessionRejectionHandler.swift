import Foundation

/// Acts on `.seerrSessionRejected` for the whole app (audit CAT-205, follow-up of CL-4).
///
/// The Catalog tab used to be the only receiver, and a tab page is not built until it is opened, so a
/// session that died while the viewer stayed on Home or Search was never re-checked. The container owns
/// this handler, which exists from launch.
///
/// A 401 means the session may be gone (idle past Seerr's 30-day store TTL, or its user or session table
/// removed), and every Retry would repeat it. The launch's own probe decides: a rejected cookie
/// disconnects, which puts the Catalog on "Set up Seerr" and closes any detail cover above it.
@MainActor
final class SeerrSessionRejectionHandler {
    private let isConnected: @MainActor () -> Bool
    private let revalidate: @MainActor () async -> Void
    private var isRevalidating = false
    private var observer: NSObjectProtocol?

    init(isConnected: @escaping @MainActor () -> Bool, revalidate: @escaping @MainActor () async -> Void) {
        self.isConnected = isConnected
        self.revalidate = revalidate
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .seerrSessionRejected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleRejection() }
        }
    }

    /// One probe at a time: a burst of 401s from a Home fan-out would otherwise start one per call.
    func handleRejection() async {
        guard isConnected(), !isRevalidating else { return }
        isRevalidating = true
        defer { isRevalidating = false }
        await revalidate()
    }
}

extension DependencyContainer {
    func revalidateSeerrSessionAfterRejection() async {
        await applySeerrSession(
            forJellyfinUserID: appState?.activeUser?.id,
            jellyfinServerID: appState?.activeServer?.id,
            allowLegacyFallback: true,
            keepsSessionOnTransientFailure: true
        )
    }
}

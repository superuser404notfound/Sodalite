#if !os(macOS)
/// A background launch (BGAppRefresh) can run without a scene, and then nothing restores the Seerr
/// session: that only happens from AppRouter's restore. The refresh handlers call this first so they
/// work without any UI (R-LIFECYCLE-4). `applySeerrSession` checks the profile and the sync
/// generation itself, so it is safe next to the router's own restore when a scene does connect.
extension DependencyContainer {
    func restoreSeerrSessionForBackgroundLaunch() async {
        guard let appState, !appState.isSeerrConnected,
              let serverID = activeServer?.id, let userID = activeUserID else { return }
        await applySeerrSession(
            forJellyfinUserID: userID,
            jellyfinServerID: serverID,
            allowLegacyFallback: true,
            disconnectUnlessConnected: false
        )
    }
}
#endif

import Foundation
import Observation

@Observable
final class AppState {
    /// Single instance (App `@State` + `@Environment` default both resolve here); mirrors DependencyContainer.shared.
    static let shared = AppState()

    var isAuthenticated = false
    var activeServer: JellyfinServer?
    var activeUser: JellyfinUser?
    /// Starts `true` so the splash covers the first frame, else the underlying view flashes before AppRouter flips it.
    var isLoading = true

    var activeSeerrServer: SeerrServer?
    var activeSeerrUser: SeerrUser?

    /// `sodalite://item/{id}` id set by onOpenURL (usually TopShelf); AppRouter clears it after presenting so a repeat tap re-fires. The deep-link signal field.
    var pendingDeepLinkItemID: String?

    /// Set with pendingDeepLinkItemID when the link was the TopShelf's playAction. AppRouter forwards it into DetailRouterView, which starts playback once. Cleared with the id.
    var pendingDeepLinkAutoPlay = false

    /// Flipped by ContinueWatchingIntent; AppRouter fetches the latest Resume item then routes via pendingDeepLinkItemID. Separate because the intent runs before the target item is known.
    var requestContinueWatching: Bool = false

    /// Bumped by DependencyContainer after a server switch; consumers (Home) observe via `.task(id:)` to clear caches + reload. Int (not Date) so back-to-back switches always change the value.
    var serverDidSwitch: Int = 0

    /// Server id a switch could not resume a session for (Sodalite#74, the normal state for a server
    /// restored from iCloud with several profiles). AppRouter resolves it into that server's profile
    /// picker and clears it; the current session stands until a profile there is picked.
    var pendingProfilePickerServerID: String?

    /// Name of the profile whose saved sign-in the server refused, set by the paths that drop it
    /// (Sodalite#90). The picker the session lands on says so once and clears it, so a card that
    /// disappears is explained on the screen it disappeared from.
    var rejectedProfileName: String?

    /// Bumped by the deep-link path to dismiss a presented player before the new sheet, else a TopShelf tap brings the app forward with the stale player on top. Detail views driving a PlayerLauncher clear showPlayer on change.
    var requestPlayerDismissal: Int = 0

    /// True while a deep-link is in flight; AppRouter overlays a loading view so the prior detail view doesn't flash.
    var isResolvingDeepLink: Bool = false

    /// True while this device withholds Local Network access, which makes every LAN server
    /// unreachable from this app alone while the same address still works in Safari (Sodalite#92).
    /// Written only by `LocalNetworkAccess`, and only after it asked the system rather than read the
    /// error text. AppRouter renders the explanation over everything, because with the permission
    /// off nothing behind it works, and clears the flag when a foreground re-probe disagrees.
    var isLocalNetworkDenied = false

    /// Whether the active Jellyfin server answers from where this device is standing, as measured
    /// by the route probe rather than inferred from a failed request (Sodalite#122). Written only
    /// by the Jellyfin leg of the route resolve, and deliberately not by the Seerr leg: a LAN-only
    /// Seerr beside a Jellyfin on a public name says nothing about whether Home can load.
    ///
    /// Home reads it to stop waiting for its own timeouts. Offline downloads (#81) becomes the
    /// second consumer, which is why the verdict is app state and not a thrown error: "run this
    /// session against the server or against the disk" is one question asked once at launch, not a
    /// per-request failure, and the same fact must not end up re-derived by a second rule that
    /// drifts from this one.
    var serverReachability: ServerReachability = .unknown

    /// Bumped when something outside a feature has made its last failure obsolete, so everything
    /// that gave up while the server was out of reach tries again. Raised by the return from a Local
    /// Network denial (the permission is back) and by `serverReachability` improving to `.reachable`.
    ///
    /// Read by more than Home, and that is the point (Sodalite#122). The session learns three things
    /// from the server exactly once, at launch, so a launch that happened while the server was
    /// unreachable never learned them at all: who the token resolves to (profile name, avatar,
    /// permissions), whether Seerr is connected, and which optional tabs this server offers. Before
    /// this signal reached them, coming back onto the network reloaded Home and left the profile
    /// picture blank, Seerr claiming it was never set up, and the Live TV and Music tabs missing
    /// until the app was force-quit. Measured on both paths, 2026-09-05.
    var requestContentReload: Int = 0

    /// True while the fresh-install launch gate is waiting on the first iCloud fetch; SplashView surfaces a status line.
    var isCloudSyncProbing = false

    var isSeerrConnected: Bool {
        activeSeerrServer != nil && activeSeerrUser != nil
    }

    func setAuthenticated(server: JellyfinServer, user: JellyfinUser) {
        activeServer = server
        activeUser = user
        isAuthenticated = true
        // A verdict belongs to the server it was measured on. Carrying one across a switch would
        // let the box you just left speak for the one you just picked, for the two seconds until
        // its own probe lands (Sodalite#122).
        serverReachability = .unknown
    }

    /// Replaces activeUser.name + .policy (preserving other fields) after a profile switch/restore once getCurrentUser() returns the server's own view: policy, else the keychain stub's policy: nil keeps permission-gated UI hidden until logout/login; name, because the keychain bootstrap can carry another server's profile name from an install predating the per-server name resolution.
    func updateActiveUserIdentity(name: String, policy: JellyfinUser.Policy?) {
        guard let current = activeUser else { return }
        activeUser = JellyfinUser(
            id: current.id,
            name: name,
            serverID: current.serverID,
            hasPassword: current.hasPassword,
            primaryImageTag: current.primaryImageTag,
            policy: policy
        )
    }

    /// Replaces activeServer with a fresh copy (applies an updated version after a server upgrade). id guard so a racing switch doesn't apply another server's data.
    func updateActiveServer(_ server: JellyfinServer) {
        guard activeServer?.id == server.id else { return }
        activeServer = server
    }

    /// Same id-guarded replace as updateActiveServer, for the Seerr server (URL slot edits).
    func updateActiveSeerrServer(_ server: SeerrServer) {
        guard activeSeerrServer?.id == server.id else { return }
        activeSeerrServer = server
    }

    func logout() {
        activeServer = nil
        activeUser = nil
        isAuthenticated = false
        activeSeerrServer = nil
        activeSeerrUser = nil
    }

    func setSeerrConnected(server: SeerrServer, user: SeerrUser) {
        activeSeerrServer = server
        activeSeerrUser = user
    }

    func disconnectSeerr() {
        activeSeerrServer = nil
        activeSeerrUser = nil
    }
}

extension AppState {
    /// Scope for this session's FilterCache entries; nil before a user is resolved, which leaves a grid uncached rather than cached under a guess. The serverID fallback mirrors HomeViewModel's own, so the tile precompute and the grid it pre-warms land on one identity.
    var cacheIdentity: CacheIdentity? {
        guard let userID = activeUser?.id else { return nil }
        return CacheIdentity(serverID: activeServer?.id ?? userID, userID: userID)
    }
}

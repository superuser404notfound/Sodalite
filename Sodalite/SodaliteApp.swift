import SwiftUI
import AetherEngine
import UIKit

#if os(iOS)
/// Drives app orientation: the app rotates freely on iPhone; a fullscreen player session narrows it
/// via PlayerOrientation.playerMask (nil in follow mode = free rotation); iPad allows all. The
/// delegate method overrides Info.plist at runtime.
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return PlayerOrientation.playerMask ?? .allButUpsideDown
    }
}
#endif

@main
struct SodaliteApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    #endif

    // Shared singletons, NOT fresh instances: SwiftUI may build the App value and the @Environment default separately, and a fresh DependencyContainer spawns a zombie MusicPlaybackCoordinator that clears system Now-Playing on every engine state change.
    @State private var appState = AppState.shared
    @State private var dependencies = DependencyContainer.shared

    init() {
        // Back-wire so switchServer/removeServer can bump serverDidSwitch; must run before any switch fires.
        dependencies.appState = appState

        // Now that appState is wired, connect the pending-requests monitor (reads appState + Seerr service).
        dependencies.wirePendingRequestsMonitor()

        #if os(iOS)
        // Register the background refresh that fires a local notification when new requests await approval.
        let deps = dependencies
        PendingRequestsBackgroundRefresh.register {
            let prefs = deps.seerrNotificationPreferences
            guard prefs.notifyPendingRequests else { return false }
            await PendingRequestsSync.refreshAndSync(
                monitor: deps.pendingRequestsMonitor,
                preferences: prefs,
                jellyfinServerID: deps.activeServer?.id,
                jellyfinUserID: deps.activeUserID
            )
            return true
        }
        // Show notifications as banners even while the app is foregrounded.
        PendingRequestsNotifier.configureForegroundPresentation()
        #endif

        // Hand the live AppState/DependencyContainer to the intent layer so AppIntent.perform() drives navigation without rebuilding its own DI graph.
        IntentBridge.bind(appState: appState, dependencies: dependencies)

        // Cloud sync: attach after the container is fully built, then register
        // for the silent CloudKit pushes that drive near-real-time propagation.
        dependencies.attachCloudSync()
        Task { @MainActor in
            UIApplication.shared.registerForRemoteNotifications()
        }

        // Wire AetherEngine diagnostics into LogTap on EVERY build, App Store included: a playback bug
        // reported after 1.0 is only cheap to fix if the reporter can read the engine's own lines out of
        // Settings > Diagnostic Log instead of needing a Mac and a TestFlight seat. `.verbose` lines stay
        // out of this by construction (EngineLog sends those to OSLog .debug only), and LogTap.note strips
        // credentials on the way in, since a log this reachable is a log that gets pasted into an issue.
        EngineLog.handler = { line in
            LogTap.shared.note(line)
        }

#if DEBUG
        // A measurement that outlives the app: the in-memory buffer is 300 lines and is wiped on
        // every launch, so a test that ends with the app being force-quit or terminated in the
        // background comes back with nothing in it. Debug builds only.
        LogTap.startFileSink()
#endif

        // The engine's own fetches, and AVPlayer's behind the AE#495 relay, answer a server-trust
        // challenge from the same pin store the app's sessions read. Same fingerprint, same
        // comparison, so browsing and playback cannot disagree about one origin: without this a
        // self-signed server would list its library and then refuse to play a frame.
        EngineTLS.serverTrustEvaluator = { space in
            guard let trust = space.serverTrust,
                  let offered = CertificateFingerprint.sha256(ofLeafIn: trust)
            else { return false }
            let host = ServerTrustStore.hostKey(host: space.host, port: space.port)
            return ServerTrustDelegate.shared.store.pinnedFingerprint(forHost: host) == offered
        }

        // Let the network layer raise the Local Network state without knowing what an AppState is
        // (Sodalite#92). Any request against a LAN server can be the one that finds out, so the
        // answer travels this way rather than up one call stack that happened to notice.
        #if os(iOS)
        let state = appState
        LocalNetworkAccess.onDenial = { state.isLocalNetworkDenied = true }
        #endif

        // Re-derive the cached TestFlight/sandbox flag from StoreKit 2; takes effect next launch (see LogTap.isDiagnosticBuild).
        Task {
            await LogTap.refreshDiagnosticBuildFlag()
        }
    }

    var body: some Scene {
        let theme = dependencies.appearancePreferences.resolvedTheme(
            isSupporter: dependencies.storeKitService.isSupporter
        )
        WindowGroup {
            AppRouter()
                .environment(\.appState, appState)
                .environment(\.dependencies, dependencies)
                .environment(\.appearanceTheme, theme)
                .preferredColorScheme(.dark)
                .tint(theme.palette.control.color)
                // The extension draws the Top Shelf resume bar in this colour. Keyed on the
                // resolved value, not the stored preset, so losing supporter status moves the
                // shelf back to a free accent along with the rest of the app.
                .task(id: theme.palette.control.hex) {
                    TopShelfAccent.write(theme.palette.control.hex)
                }
                // Same bridge, same reason: the extension cannot read the app's preferences.
                .task(id: dependencies.appearancePreferences.showTopShelfRow) {
                    TopShelfEnabled.write(dependencies.appearancePreferences.showTopShelfRow)
                }
                // Third crossing of the same bridge. The shelf is redrawn afterwards because the
                // cells it is holding were built from the old choice and nothing else will ask.
                .task(id: dependencies.appearancePreferences.topShelfImage) {
                    TopShelfArtwork.write(rawValue: dependencies.appearancePreferences.topShelfImage.rawValue)
                    TopShelfRefresher.invalidate()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// Handles `sodalite://item/{id}` and `sodalite://play/{id}` (TopShelf's display and play actions): stashes the id in AppState for AppRouter to resolve. Synchronously tears down any active player modal first, else a TopShelf tap waking the app from a paused player loses ~10s to the player's own appDidBecomeActive reload before AppRouter's .task(id:) cycles in.
    private func handleDeepLink(_ url: URL) {
        guard let route = DeepLinkRoute.parse(url) else { return }
        PlayerModalDismisser.dismissActive(logPrefix: "[SodaliteApp]")
        appState.requestPlayerDismissal &+= 1
        // Mask the prior detail view during the fetch + cover slide-in; AppRouter clears this once the new sheet takes over.
        appState.isResolvingDeepLink = true
        // Assigned before the id: AppRouter's .task is keyed on the id, so the flag has to be in place when it fires.
        appState.pendingDeepLinkAutoPlay = route.autoPlay
        appState.pendingDeepLinkItemID = route.itemID
    }
}

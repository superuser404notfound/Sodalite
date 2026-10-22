import Foundation
import AetherEngine
#if canImport(UIKit)
import UIKit
#endif

/// Non-destructive twin of PlayerModalDismisser's modal walk: reports whether a player
/// session is on screen (modal PlayerHostController, or tvOS PiP with no modal to walk).
/// Used to skip the profile reprompt over active playback (issue #41).
@MainActor
enum PlayerModalPresence {
    static func notifyDidChange() {
        NotificationCenter.default.post(name: .playerModalPresenceDidChange, object: nil)
    }

    #if os(macOS)
    /// Sessions on screen. The Mac player is a SwiftUI view with no modal chain to walk, so it says
    /// so itself: `MacPlayerScreen` holds a claim for as long as it is mounted. A count rather than
    /// a flag because a session handed from one screen to the next mounts the new one before the
    /// old one goes away.
    private static var claims = 0

    static func claimPlayerActive() {
        claims += 1
        notifyDidChange()
    }

    static func releasePlayerActive() {
        claims = max(0, claims - 1)
        notifyDidChange()
    }

    static var isPlayerActive: Bool { claims > 0 }
    #else
    static var isPlayerActive: Bool {
        #if os(tvOS)
        if PiPSessionCoordinator.shared.hasActiveSession { return true }
        #endif
        return presentedPlayer() != nil
    }

    private static func presentedPlayer() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else { return nil }

        var presenter: UIViewController? = window.rootViewController
        while let current = presenter {
            guard let presented = current.presentedViewController else { break }
            if PlayerLauncherHostVC.isPlayer(presented) { return presented }
            presenter = presented
        }
        return nil
    }
    #endif

    /// A session on screen that is also moving: playing in place, in PiP, over AirPlay or as
    /// background audio. A paused one does not count, see `ProfileRepromptPolicy`. A multiview grid
    /// always counts, its tiles have no shared pause.
    static var isPlaybackRunning: Bool {
        guard isPlayerActive else { return false }
        #if os(tvOS)
        if presentedPlayer() is MultiviewHostController { return true }
        #endif
        return DependencyContainer.playerEngine.state == .playing
    }
}

import UIKit

/// Non-destructive twin of PlayerModalDismisser's modal walk: reports whether a player
/// session is on screen (modal PlayerHostController, or tvOS PiP with no modal to walk).
/// Used to skip the profile reprompt over active playback (issue #41).
@MainActor
enum PlayerModalPresence {
    static func notifyDidChange() {
        NotificationCenter.default.post(name: .playerModalPresenceDidChange, object: nil)
    }

    static var isPlayerActive: Bool {
        #if os(tvOS)
        if PiPSessionCoordinator.shared.hasActiveSession { return true }
        #endif
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else { return false }

        var presenter: UIViewController? = window.rootViewController
        while let current = presenter {
            guard let presented = current.presentedViewController else { break }
            if PlayerLauncherHostVC.isPlayer(presented) { return true }
            presenter = presented
        }
        return false
    }
}

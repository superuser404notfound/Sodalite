import UIKit
import AetherEngine

/// Shared deep-link teardown for the UIKit player modal (SodaliteApp URL handler + AppRouter resolver). Used because the SwiftUI binding-only dismiss proved unreliable across the scene-foreground transition (a TopShelf resume from a paused player didn't always reach UIKit fast enough for the new cover to present on top).
@MainActor
enum PlayerModalDismisser {
    /// Walks the active scene's modal chain and dismisses PlayerHostController if presented (dismissing the direct presenter leaves other modal levels alone). Logged via EngineLog with `logPrefix` for TestFlight overlay confirmation.
    static func dismissActive(logPrefix: String) {
        #if os(tvOS)
        // Deep-link teardown must also cover a session living in the PiP window (no modal to walk).
        PiPSessionCoordinator.shared.endActiveSession()
        #endif
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else {
            EngineLog.emit("\(logPrefix) deep-link dismiss: no key window")
            return
        }

        var presenter: UIViewController? = window.rootViewController
        while let current = presenter {
            guard let presented = current.presentedViewController else { break }
            #if os(tvOS)
            if let grid = presented as? MultiviewHostController {
                EngineLog.emit("\(logPrefix) deep-link dismiss: stopping multiview")
                grid.coordinator.stopAll()
                if current.presentedViewController === grid { current.dismiss(animated: false) }
                return
            }
            #endif
            if presented is PlayerHostController {
                EngineLog.emit("\(logPrefix) deep-link dismiss: tearing down active player modal")
                current.dismiss(animated: false)
                return
            }
            presenter = presented
        }
        EngineLog.emit("\(logPrefix) deep-link dismiss: no player in modal chain")
    }
}

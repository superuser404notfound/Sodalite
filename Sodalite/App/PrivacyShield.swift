#if !os(macOS)
import SwiftUI
import UIKit

/// Dark glass with the logo, laid over the whole app on the way out while a who's-watching reprompt
/// is possible (Sodalite#184). The system snapshot taken at that moment is what a returning viewer
/// sees first, and without the shield it showed the previous profile's page, which then closed
/// behind the picker. Its own window, because the detail and player covers sit above the router.
@MainActor
enum PrivacyShield {
    private static var window: UIWindow?
    /// Bumped on every raise, so a fade that started before it cannot hide the new shield.
    private static var generation = 0

    static var isRaised: Bool { window != nil }

    static func raise(isSupporter: Bool) {
        generation &+= 1
        if let window {
            window.layer.removeAllAnimations()
            window.alpha = 1
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else { return }
        let host = UIHostingController(rootView: PrivacyShieldView(isSupporter: isSupporter))
        host.view.backgroundColor = .clear
        let shield = UIWindow(windowScene: scene)
        shield.windowLevel = .alert + 1
        shield.rootViewController = host
        // Never key and never touchable: focus and touches stay with the app underneath.
        shield.isUserInteractionEnabled = false
        shield.isHidden = false
        shield.layoutIfNeeded()
        window = shield
    }

    static func lower(after delay: Duration = .zero) {
        guard window != nil else { return }
        let lowering = generation
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard lowering == generation, let shield = window else { return }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                shield.alpha = 0
            } completion: { _ in
                guard lowering == generation else { return }
                shield.isHidden = true
                window = nil
            }
        }
    }
}

private struct PrivacyShieldView: View {
    let isSupporter: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThickMaterial)
            Color.Theme.scrim
            Image(isSupporter ? "PremiumLogo_Hero" : "Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 280, height: 280)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
#endif

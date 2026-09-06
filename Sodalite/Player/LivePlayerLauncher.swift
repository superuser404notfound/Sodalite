import SwiftUI
import UIKit

// MARK: - Live Player Launcher (UIKit modal presentation)

/// UIKit-modal launcher for the live player (mirrors PlayerLauncher with the
/// live initializer); presents when `isPresented` and `context` are set.
struct LivePlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let context: LivePlaybackContext?
    let playbackService: JellyfinPlaybackServiceProtocol
    let liveTvService: JellyfinLiveTvServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    let directStreamMemory: LiveDirectStreamMemory
    /// Same reason as PlayerLauncher: the theme has to be picked up on the SwiftUI side and carried
    /// across the UIKit boundary by hand.
    @Environment(\.appearanceTheme) private var appearanceTheme

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        if isPresented, let liveContext = self.context {
            guard host.viewIfLoaded?.window != nil else { return }
            if host.presentedViewController is PlayerHostController || host.pendingLivePresent { return }
            host.pendingLivePresent = true
            attemptPresent(host: host, liveContext: liveContext, attempt: 0)
        } else if !isPresented, host.presentedViewController is PlayerHostController {
            // Programmatic dismissal (sign-out, deep link, teardown); else the
            // live player stays as a zombie modal.
            host.dismiss(animated: false)
        }
    }

    /// Anything still presented ANYWHERE above the window root blocks the player: UIKit refuses to
    /// present from a controller whose chain is already presenting. Checking only the host missed
    /// the iPhone channel list, which can be two sheets deep and is not presenting from the host,
    /// so the poll passed instantly and the present failed silently (a dead "Watch live" button).
    /// Strictly more conservative than the old check: it can only wait longer, never shorter.
    private func blockingPresentation(above host: PlayerLauncherHostVC) -> UIViewController? {
        var cursor: UIViewController? = host.view.window?.rootViewController ?? host
        var blocker: UIViewController?
        while let presented = cursor?.presentedViewController {
            if !(presented is PlayerHostController) { blocker = presented }
            cursor = presented
        }
        return blocker
    }

    /// Present only once the info popover (a SwiftUI sheet) has finished dismissing; presenting
    /// mid-dismiss fails ("view is not in the window hierarchy"), so poll (40 x 50ms) until
    /// nothing above the host is presented.
    private func attemptPresent(host: PlayerLauncherHostVC, liveContext: LivePlaybackContext, attempt: Int) {
        // Binding can flip false during the poll (user backed out); don't
        // launch a player nobody asked for.
        guard isPresented else {
            host.pendingLivePresent = false
            return
        }
        if blockingPresentation(above: host) != nil {
            guard attempt < 40 else { host.pendingLivePresent = false; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                attemptPresent(host: host, liveContext: liveContext, attempt: attempt + 1)
            }
            return
        }
        host.pendingLivePresent = false
        if host.presentedViewController is PlayerHostController { return }

        // Second video while PiP runs: close the PiP session first (progress reported), Netflix behavior.
        #if os(tvOS)
        PiPSessionCoordinator.shared.endActiveSession()
        #endif

        let item = JellyfinItem(liveChannel: liveContext.channel, program: liveContext.program)
        let vm = PlayerViewModel(
            item: item,
            startFromBeginning: true,
            playbackService: playbackService,
            userID: userID,
            preferences: preferences,
            isLiveSession: true,
            liveChannel: liveContext.channel,
            liveProgram: liveContext.program,
            liveTvService: liveTvService,
            directStreamMemory: directStreamMemory
        )
        let playerVC = PlayerHostController(
            viewModel: vm,
            theme: appearanceTheme,
            onDismiss: {
                host.dismiss(animated: false) { isPresented = false }
            }
        )
        playerVC.modalPresentationStyle = .fullScreen
        host.present(playerVC, animated: false)
    }
}

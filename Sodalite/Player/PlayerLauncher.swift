import SwiftUI
import UIKit

// MARK: - Player Launcher (UIKit modal presentation)

/// Presents PlayerHostController as a UIKit modal (NOT SwiftUI
/// fullScreenCover, which on tvOS intercepts Menu at the presentation level so
/// child-VC press handlers / .onExitCommand never fire).
struct PlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let item: JellyfinItem?
    let startFromBeginning: Bool
    let playbackService: JellyfinPlaybackServiceProtocol
    /// Lets a session whose movie was replaced under it (a Radarr upgrade rewrites the file, so Jellyfin
    /// mints a new id) resolve the new item instead of dying on the old one. Episodes do not need it.
    var itemService: JellyfinItemServiceProtocol?
    let userID: String
    let preferences: PlaybackPreferences
    /// Sodalite#46 per-title track memory; nil disables remembering for this launch.
    var trackMemory: TrackSelectionMemory?
    /// Sodalite#50 spoiler decision, snapshotted by the caller; .disabled leaves the player alone.
    var spoilerPolicy: SpoilerPolicy = .disabled
    /// Detail-screen prefetch, saving the first round trip. It names the item it was fetched for and
    /// the player drops it unless that is the item being launched (Sodalite#71).
    var cachedPlaybackInfo: PrefetchedPlaybackInfo?
    /// Version picker's choice; nil = default-first source.
    var preferredMediaSourceID: String?
    /// Shuffle / play queue; empty = single-item playback.
    var playQueue: [JellyfinItem] = []
    /// Read here, on the SwiftUI side, because a UIHostingController inside the UIKit modal starts
    /// from a BLANK environment: every `\.appearanceTheme` read below it silently falls back to
    /// `ResolvedAppearanceTheme.default`, which is system blue.
    @Environment(\.appearanceTheme) private var appearanceTheme

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        if isPresented, let item, host.presentedPlayer == nil, !host.isLaunching {
            // Latch the launch so a re-render while we wait for the presentation
            // context to settle can't build a second PlayerViewModel (each one
            // re-requests PlaybackInfo) -- the churn that crashed #31.
            host.isLaunching = true
            let isPresentedBinding = _isPresented
            host.presentWhenContextIsFree {
                let vm = PlayerViewModel(
                    item: item,
                    startFromBeginning: startFromBeginning,
                    playbackService: playbackService,
                    userID: userID,
                    preferences: preferences,
                    itemService: itemService,
                    trackMemory: trackMemory,
                    spoilerPolicy: spoilerPolicy,
                    cachedPlaybackInfo: cachedPlaybackInfo,
                    preferredMediaSourceID: preferredMediaSourceID,
                    playQueue: playQueue
                )
                let playerVC = PlayerHostController(
                    viewModel: vm,
                    theme: appearanceTheme,
                    onDismiss: { [weak host] in
                        // Reset the trigger unconditionally and synchronously.
                        // PlayerHostController also self-dismisses on iOS, so a reset
                        // gated on the dismiss completion gets dropped -- leaving
                        // showPlayer stuck true, which a rotation / re-render then
                        // relaunches into a fresh launcher host (#31 reopen-on-rotate).
                        isPresentedBinding.wrappedValue = false
                        host?.tearDownPlayer(nil)
                    }
                )
                playerVC.modalPresentationStyle = .fullScreen
                #if os(iOS)
                // Engage the orientation mode BEFORE presenting: the system validates the player VC's
                // supportedInterfaceOrientations against the app's allowed set at present time, so in
                // locked mode the delegate must already permit landscape or it throws "no common orientation".
                PlayerOrientation.engage(locked: preferences.playerRotationLocked, session: playerVC.orientationSession)
                #endif
                return playerVC
            }
        } else if !isPresented {
            // User backed out / programmatic dismissal. Cancel a queued present and
            // tear down a live player if one is up.
            host.cancelPendingLaunch()
            if host.presentedPlayer != nil {
                host.tearDownPlayer(nil)
            }
        }
    }
}

/// Invisible host VC: anchors the launcher in the SwiftUI tree but does NOT
/// present the player itself. The overlay this lives in can be detached from
/// the window by SwiftUI mid-launch (its `view.window` goes nil), so the player
/// is presented from the scene's top-most settled view controller instead and
/// tracked here for teardown.
final class PlayerLauncherHostVC: UIViewController {
    /// Guards the live-player present retry loop against duplicate launches.
    var pendingLivePresent = false
    /// A launch is in flight (waiting for a free presentation context). Blocks
    /// `updateUIViewController` from starting a second one, which would
    /// re-request PlaybackInfo (#31).
    var isLaunching = false
    /// The currently presented player, presented from the scene top-most VC (not
    /// from `self`). Held so teardown can dismiss it regardless of where `self`
    /// sits in the hierarchy.
    weak var presentedPlayer: UIViewController?
    /// Bumped on every launch request and on cancel so a stale, queued present
    /// attempt bails instead of presenting a player the user no longer wants.
    private var launchGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    /// Presents the player once the scene's presentation chain is settled.
    ///
    /// The version-picker sheet shares the detail screen's presentation context.
    /// Presenting the player while that sheet is still dismissing crashed the app
    /// back to Home on slower hardware (#31). The earlier fixes either guessed a
    /// fixed delay (lost the race on a 2015 Apple TV) or gated on `self.view.window`
    /// (which goes nil mid-launch on iOS, so the player never appeared). This waits
    /// on the scene's top-most view controller settling, then presents from it.
    func presentWhenContextIsFree(_ build: @escaping () -> UIViewController) {
        launchGeneration &+= 1
        attemptPresent(generation: launchGeneration, build: build, attempts: 0)
    }

    /// Invalidates any queued present and clears the launch latch.
    func cancelPendingLaunch() {
        launchGeneration &+= 1
        isLaunching = false
    }

    /// Dismisses the presented player (from whatever VC presented it) and clears
    /// the launch latch.
    func tearDownPlayer(_ completion: (() -> Void)?) {
        isLaunching = false
        guard let player = presentedPlayer else {
            completion?()
            return
        }
        presentedPlayer = nil
        let presenter = player.presentingViewController ?? player
        presenter.dismiss(animated: false, completion: completion)
    }

    private func attemptPresent(generation: Int, build: @escaping () -> UIViewController, attempts: Int) {
        // Superseded by a newer request or cancelled.
        guard generation == launchGeneration, isLaunching, presentedPlayer == nil else { return }

        // App-wide single-player guard. Multiple launcher hosts can be mid-launch
        // at once (a host can be orphaned from the window while a sibling launches),
        // and presenting from the scene top-most VC means an orphan could otherwise
        // stack a second player. If any player is already on screen, bail for good
        // instead of polling -- else this host would present again the moment the
        // first player is dismissed.
        if sceneHasPlayer() {
            isLaunching = false
            return
        }

        guard let presenter = settledTopPresenter() else {
            // Chain busy (a sheet is presenting/dismissing) or no window yet. Poll,
            // bounded to ~3s so a wedged chain can't spin forever.
            guard attempts < 60 else {
                isLaunching = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.attemptPresent(generation: generation, build: build, attempts: attempts + 1)
            }
            return
        }

        // Second video while PiP runs: close the PiP session first (progress reported), Netflix behavior.
        #if os(tvOS)
        PiPSessionCoordinator.shared.endActiveSession()
        #endif

        let playerVC = build()
        presentedPlayer = playerVC
        presenter.present(playerVC, animated: false)
    }

    /// The scene key window's top-most presented view controller, but only when
    /// the whole chain is settled (nothing presenting/dismissing/transitioning).
    /// Returns nil while busy so the caller polls. Presenting from this VC (rather
    /// than from `self`) survives `self` being detached from the window mid-launch.
    private func settledTopPresenter() -> UIViewController? {
        let window = (view.window?.windowScene ?? activeWindowScene())?
            .windows.first(where: { $0.isKeyWindow })
            ?? view.window
        guard var top = window?.rootViewController else { return nil }
        if top.transitionCoordinator != nil { return nil }
        while let presented = top.presentedViewController {
            if presented.isBeingDismissed || presented.isBeingPresented || presented.transitionCoordinator != nil {
                return nil
            }
            top = presented
        }
        // A player is already up here -- don't stack a second one.
        if top is PlayerHostController { return nil }
        return top
    }

    /// True if a player is already presented anywhere in the key window's chain.
    private func sceneHasPlayer() -> Bool {
        let window = (view.window?.windowScene ?? activeWindowScene())?
            .windows.first(where: { $0.isKeyWindow })
            ?? view.window
        var vc = window?.rootViewController
        while let current = vc {
            if current is PlayerHostController { return true }
            vc = current.presentedViewController
        }
        return false
    }

    private func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

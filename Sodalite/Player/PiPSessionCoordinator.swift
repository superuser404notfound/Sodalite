#if os(tvOS)
import UIKit

/// Pure PiP session lifecycle (unit-tested): what to do with the retained player session on each event.
enum PiPSessionMachine {
    enum State: Equatable { case idle, active, restoring }
    enum Event: Equatable { case begin, restoreRequested, didStop, preempt, playerDismissed }
    enum Effect: Equatable {
        case none
        case represent            // re-present the retained VC (restore-to-fullscreen)
        case continueFullscreen   // restore finished: clear PiP flags, release ownership, playback continues
        case closeSession         // PiP window closed: stopPlayback + release
        case stopPiPAndClose      // preemption: close the PiP window, stopPlayback + release
        case releaseRefs          // VC dismissed itself after a restore: release only
    }

    static func transition(_ state: State, _ event: Event) -> (State, Effect) {
        switch (state, event) {
        case (.idle, .begin): return (.active, .none)
        case (.active, .begin), (.restoring, .begin): return (.active, .none)
        case (.active, .restoreRequested): return (.restoring, .represent)
        case (.restoring, .restoreRequested): return (.restoring, .none)
        case (.restoring, .didStop): return (.idle, .continueFullscreen)
        case (.active, .didStop): return (.idle, .closeSession)
        case (.active, .preempt), (.restoring, .preempt): return (.idle, .stopPiPAndClose)
        case (.idle, .preempt): return (.idle, .none)
        case (_, .playerDismissed): return (.idle, .releaseRefs)
        case (.idle, .restoreRequested), (.idle, .didStop): return (.idle, .none)
        }
    }
}

/// Owns the player while its video lives in the system PiP window. The launchers hold the VC only weakly
/// and reset their bindings at PiP start, so without this owner the dismissed VC (and the session
/// reporting in its view model) would deallocate and the PiP window would die.
@MainActor
final class PiPSessionCoordinator {
    static let shared = PiPSessionCoordinator()

    private(set) var activePlayer: PlayerHostController?
    private(set) var activeViewModel: PlayerViewModel?
    private var state: PiPSessionMachine.State = .idle
    /// Held between restoreRequested and the settled re-present so AVKit gets its answer exactly once.
    private var pendingRestoreCompletion: ((Bool) -> Void)?

    var hasActiveSession: Bool { activePlayer != nil }

    func beginSession(player: PlayerHostController, viewModel: PlayerViewModel) {
        activePlayer = player
        activeViewModel = viewModel
        apply(event: .begin)
        PlayerModalPresence.notifyDidChange()
    }

    func restore(completion: @escaping (Bool) -> Void) {
        pendingRestoreCompletion = completion
        apply(event: .restoreRequested)
    }

    func handleDidStop() { apply(event: .didStop) }

    /// Second-video preemption, deep-link teardown: close the PiP window and end the session. Safe no-op when idle.
    func endActiveSession() { apply(event: .preempt) }

    /// The restored VC dismissed itself normally (Menu): drop our refs, playback teardown already ran.
    func playerDidDismiss(_ player: PlayerHostController) {
        guard player === activePlayer else { return }
        apply(event: .playerDismissed)
    }

    private func apply(event: PiPSessionMachine.Event) {
        let (next, effect) = PiPSessionMachine.transition(state, event)
        state = next
        switch effect {
        case .none:
            break
        case .represent:
            representRetainedPlayer()
        case .continueFullscreen:
            activePlayer?.pipDidEnd()
            release()
        case .closeSession:
            activePlayer?.pipDidEnd()
            activeViewModel?.stopPlayback()
            release()
        case .stopPiPAndClose:
            pendingRestoreCompletion?(false)
            pendingRestoreCompletion = nil
            activePlayer?.pipController.stop()
            activePlayer?.pipDidEnd()
            activeViewModel?.stopPlayback()
            release()
        case .releaseRefs:
            release()
        }
    }

    private func release() {
        activePlayer = nil
        activeViewModel = nil
        PlayerModalPresence.notifyDidChange()
    }

    /// Present the retained VC from the scene's settled top-most VC (same rationale as PlayerLauncherHostVC:
    /// presenting into a mid-transition chain fails), bounded to ~3s of polling.
    private func representRetainedPlayer(attempts: Int = 0) {
        guard let player = activePlayer, let completion = pendingRestoreCompletion else { return }
        guard let presenter = settledTopPresenter() else {
            guard attempts < 60 else {
                pendingRestoreCompletion = nil
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.representRetainedPlayer(attempts: attempts + 1)
            }
            return
        }
        pendingRestoreCompletion = nil
        presenter.present(player, animated: false) { completion(true) }
    }

    private func settledTopPresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        // A multiview grid on top is a surface to restore over, not a second player.
        return PlayerLauncherHostVC.settledTopPresenter(in: window) { $0 is PlayerHostController }
    }
}
#endif

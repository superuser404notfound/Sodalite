#if os(tvOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Sodalite#167: a thumb resting on the clickpad raises the transport, the way Up already does. Apple
/// lists this as its own playback gesture (Apple TV User Guide, "Control video playback"), separate
/// from Up, and it is how the system player shows elapsed and remaining time without stopping.
enum SiriRemoteRestingTouch {
    /// How long a touch has to rest before it counts. Every click and every swipe also begins with a
    /// touch, so revealing on touch-down would change what they mean: a swipe down from hidden would
    /// raise the bar and then take it away, and a click could no longer take the next-episode prompt,
    /// which only owns Select while the transport is hidden. A click lands well inside this window,
    /// a swipe leaves it by moving. Same value as the Select hold threshold, so a press and a touch
    /// share one idea of "held".
    static let dwell: TimeInterval = 0.35

    /// Travel (pt) after which the touch is a swipe, not a rest. The pan's own axis commit threshold,
    /// so the two recognizers agree on where a rest ends and a swipe begins.
    static let slop: CGFloat = 40

    /// Whether a resting touch should raise the transport. Only from hidden, which is also what keeps
    /// focus on the progress bar (hiding resets it there), so a click after the reveal still pauses and
    /// a horizontal swipe still scrubs. Everything that owns the remote on its own keeps it.
    static func revealsTransport(
        showControls: Bool,
        overlayCapturesInput: Bool,
        nextEpisodePromptVisible: Bool
    ) -> Bool {
        !showControls && !overlayCapturesInput && !nextEpisodePromptVisible
    }
}

/// Fires once when an indirect touch has rested for `SiriRemoteRestingTouch.dwell` without moving past
/// the slop and without a press. It never recognizes, so it can neither delay nor cancel the pan and
/// press recognizers that share the view: it only watches.
final class RestingTouchGestureRecognizer: UIGestureRecognizer {
    private let onRest: @MainActor () -> Void
    private var start: CGPoint?
    private var timer: Timer?

    init(onRest: @escaping @MainActor () -> Void) {
        self.onRest = onRest
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Every press, so a click on the pad or a press anywhere else ends the rest before it fires.
        allowedPressTypes = [
            UIPress.PressType.select, .upArrow, .downArrow, .leftArrow, .rightArrow, .playPause, .menu,
        ].map { NSNumber(value: $0.rawValue) }
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, let touch = touches.first else { return }
        start = touch.location(in: view)
        timer = Timer.scheduledTimer(withTimeInterval: SiriRemoteRestingTouch.dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onRest()
                self.fail()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first else { return }
        let p = touch.location(in: view)
        if hypot(p.x - start.x, p.y - start.y) > SiriRemoteRestingTouch.slop { fail() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { fail() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { fail() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) { fail() }

    /// UIKit calls `reset()` only once the whole touch sequence is over, so the timer has to stop here:
    /// a swipe that failed the rest would otherwise still reveal the bar when the dwell ran out.
    private func fail() {
        timer?.invalidate()
        timer = nil
        if state == .possible { state = .failed }
    }

    override func reset() {
        timer?.invalidate()
        timer = nil
        start = nil
    }
}
#endif

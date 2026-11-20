#if os(tvOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports, at the start of every press, how long the remote was silent before it (Sodalite#173). A
/// touch counts as activity only once it ends: a click on the clickpad begins with a touch, so taking
/// touch-down would make every press look fresh. Like `RestingTouchGestureRecognizer` it never
/// recognizes, so it cannot delay or cancel the recognizers that share the view.
final class RemoteActivityGestureRecognizer: UIGestureRecognizer {
    private let onPress: @MainActor (TimeInterval) -> Void
    private var lastActivity = Date()

    init(onPress: @escaping @MainActor (TimeInterval) -> Void) {
        self.onPress = onPress
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        allowedPressTypes = [
            UIPress.PressType.select, .upArrow, .downArrow, .leftArrow, .rightArrow, .playPause, .menu,
            .pageUp, .pageDown,
        ].map { NSNumber(value: $0.rawValue) }
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let now = Date()
        onPress(now.timeIntervalSince(lastActivity))
        lastActivity = now
        if state == .possible { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { noteTouchEnd() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { noteTouchEnd() }

    private func noteTouchEnd() {
        lastActivity = Date()
        if state == .possible { state = .failed }
    }
}
#endif

#if !os(macOS)
// A focusable UIKit surface for the Siri Remote and the touch screen. The Mac scrubs with the pointer, on the SwiftUI slider the bar already draws.
import SwiftUI
import UIKit

/// Focusable UIKit input layer for the music scrubber, giving the SwiftUI player the same feel as the
/// (UIKit) video player. When focused: pan to scrub, left/right click to skip, hold to spool, Select
/// to commit / toggle play. The bar is drawn in SwiftUI; this transparent view owns the input and
/// reports focus up so the bar can show a focus look.
struct MusicScrubberInput: UIViewRepresentable {
    let coordinator: MusicPlaybackCoordinator
    @Binding var isFocused: Bool

    func makeCoordinator() -> Handler {
        Handler(playback: coordinator, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> ScrubInputView {
        let view = ScrubInputView()
        view.installGestures(handler: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: ScrubInputView, context: Context) {
        context.coordinator.playback = coordinator
    }

    // MARK: - Gesture target (NSObject for @objc selectors)

    final class Handler: NSObject {
        var playback: MusicPlaybackCoordinator
        let isFocused: Binding<Bool>
        private var panStartFraction: Double = 0

        init(playback: MusicPlaybackCoordinator, isFocused: Binding<Bool>) {
            self.playback = playback
            self.isFocused = isFocused
        }

        @objc func leftTapped() { playback.seekSkip(direction: -1) }
        @objc func rightTapped() { playback.seekSkip(direction: 1) }

        @objc func leftHeld(_ g: UILongPressGestureRecognizer) { handleHold(g, direction: -1) }
        @objc func rightHeld(_ g: UILongPressGestureRecognizer) { handleHold(g, direction: 1) }

        private func handleHold(_ g: UILongPressGestureRecognizer, direction: Int) {
            switch g.state {
            case .began: playback.beginContinuousSeek(direction: direction)
            case .ended, .cancelled, .failed: playback.endContinuousSeek()
            default: break
            }
        }

        @objc func selectTapped() {
            if playback.isScrubbing {
                playback.commitScrub()
            } else {
                playback.togglePlayPause()
            }
        }

        /// Touchpad travel (points) for a full-track scrub. Large/deliberate because the Siri Remote
        /// over-reports indirect-touch translation; matches the video player's t.x/fullScreenWidth*0.3 ~= t.x/6400.
        private static let scrubTravelForFullTrack: CGFloat = 6400

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began:
                playback.scrubBegan()
                panStartFraction = playback.scrubProgress
            case .changed:
                let translation = g.translation(in: view).x
                playback.scrub(toFraction: panStartFraction + Double(translation / Self.scrubTravelForFullTrack))
            default:
                break
            }
        }

        func focusChanged(_ focused: Bool) {
            isFocused.wrappedValue = focused
            // Navigating away mid-scrub discards the preview.
            if !focused && playback.isScrubbing {
                playback.cancelScrub()
            }
        }
    }
}

// MARK: - The focusable UIView

final class ScrubInputView: UIView {
    private weak var handler: MusicScrubberInput.Handler?

    override var canBecomeFocused: Bool { true }

    func installGestures(handler: MusicScrubberInput.Handler) {
        self.handler = handler

        #if os(tvOS)
        let pan = UIPanGestureRecognizer(target: handler, action: #selector(MusicScrubberInput.Handler.handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        addGestureRecognizer(pan)

        let leftTap = press(.leftArrow, action: #selector(MusicScrubberInput.Handler.leftTapped), target: handler)
        let leftHold = hold(.leftArrow, action: #selector(MusicScrubberInput.Handler.leftHeld(_:)), target: handler)
        leftTap.require(toFail: leftHold)

        let rightTap = press(.rightArrow, action: #selector(MusicScrubberInput.Handler.rightTapped), target: handler)
        let rightHold = hold(.rightArrow, action: #selector(MusicScrubberInput.Handler.rightHeld(_:)), target: handler)
        rightTap.require(toFail: rightHold)

        _ = press(.select, action: #selector(MusicScrubberInput.Handler.selectTapped), target: handler)
        #else
        // PORT SEAM (iOS, Phase 3): attach touch scrub gestures here.
        #endif
    }

    private func press(_ type: UIPress.PressType, action: Selector, target: Any) -> UITapGestureRecognizer {
        let t = UITapGestureRecognizer(target: target, action: action)
        t.allowedPressTypes = [NSNumber(value: type.rawValue)]
        addGestureRecognizer(t)
        return t
    }

    private func hold(_ type: UIPress.PressType, action: Selector, target: Any) -> UILongPressGestureRecognizer {
        let h = UILongPressGestureRecognizer(target: target, action: action)
        h.allowedPressTypes = [NSNumber(value: type.rawValue)]
        h.minimumPressDuration = 0.35
        addGestureRecognizer(h)
        return h
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        handler?.focusChanged(context.nextFocusedView === self)
    }
}
#endif

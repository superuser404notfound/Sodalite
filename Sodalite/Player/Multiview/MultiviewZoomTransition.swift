#if os(tvOS)
import UIKit

/// Sodalite#175: a tile's full screen grows out of the tile, and Back shrinks it into the tile again.
/// Presenting zooms the player itself, which already shows the picture. Dismissing zooms the grid out of
/// the tile instead: by then the player has handed the picture back to the tile, so the tile is the only
/// view that still moves with live video in it.
@MainActor
final class MultiviewZoomTransition: NSObject, UIViewControllerTransitioningDelegate {
    static let duration: TimeInterval = 0.35
    static let tileCornerRadius: CGFloat = 12

    /// The tile in window coordinates, refreshed before every presentation and dismissal.
    var tileFrame: CGRect = .zero

    /// Nil means no zoom: Reduce Motion is on, or the grid never reported where the tile is.
    static func zoomFrame(tileFrame: CGRect?, reduceMotion: Bool) -> CGRect? {
        guard !reduceMotion, let tileFrame, !tileFrame.isNull, !tileFrame.isInfinite,
              tileFrame.width > 1, tileFrame.height > 1 else { return nil }
        return tileFrame
    }

    /// Maps a view filling `bounds` onto `tile`, applied about the view's centre as UIKit does.
    static func transform(onto tile: CGRect, from bounds: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: tile.midX - bounds.midX, y: tile.midY - bounds.midY)
            .scaledBy(x: tile.width / bounds.width, y: tile.height / bounds.height)
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        Animator(tileFrame: tileFrame, isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(tileFrame: tileFrame, isPresenting: false)
    }

    private final class Animator: NSObject, UIViewControllerAnimatedTransitioning {
        let tileFrame: CGRect
        let isPresenting: Bool

        init(tileFrame: CGRect, isPresenting: Bool) {
            self.tileFrame = tileFrame
            self.isPresenting = isPresenting
        }

        func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
            MultiviewZoomTransition.duration
        }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            if isPresenting { present(context) } else { dismiss(context) }
        }

        private func present(_ context: UIViewControllerContextTransitioning) {
            guard let toVC = context.viewController(forKey: .to), let toView = context.view(forKey: .to) else {
                context.completeTransition(!context.transitionWasCancelled)
                return
            }
            let container = context.containerView
            let bounds = context.finalFrame(for: toVC)
            container.addSubview(toView)
            toView.frame = bounds
            let tile = container.convert(tileFrame, from: nil)
            let transform = MultiviewZoomTransition.transform(onto: tile, from: bounds)
            toView.transform = transform
            toView.layer.cornerRadius = MultiviewZoomTransition.tileCornerRadius / max(transform.a, 0.01)
            toView.layer.cornerCurve = .continuous
            toView.layer.masksToBounds = true
            UIView.animate(
                withDuration: MultiviewZoomTransition.duration,
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                toView.transform = .identity
                toView.layer.cornerRadius = 0
            } completion: { _ in
                toView.transform = .identity
                toView.layer.cornerRadius = 0
                toView.layer.masksToBounds = false
                context.completeTransition(!context.transitionWasCancelled)
            }
        }

        private func dismiss(_ context: UIViewControllerContextTransitioning) {
            guard let fromView = context.view(forKey: .from),
                  let toVC = context.viewController(forKey: .to) else {
                context.completeTransition(!context.transitionWasCancelled)
                return
            }
            let container = context.containerView
            let bounds = context.finalFrame(for: toVC)
            // A full-screen presentation took the grid out of the window; it comes back under the player.
            let grid: UIView
            if let returning = context.view(forKey: .to) {
                container.insertSubview(returning, belowSubview: fromView)
                returning.frame = bounds
                grid = returning
            } else {
                grid = toVC.view
            }
            let tile = container.convert(tileFrame, from: nil)
            grid.transform = MultiviewZoomTransition.transform(onto: tile, from: bounds).inverted()
            UIView.animate(withDuration: MultiviewZoomTransition.duration * 0.4) {
                fromView.alpha = 0
            }
            UIView.animate(
                withDuration: MultiviewZoomTransition.duration,
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                grid.transform = .identity
            } completion: { _ in
                grid.transform = .identity
                let finished = !context.transitionWasCancelled
                if !finished { fromView.alpha = 1 }
                context.completeTransition(finished)
            }
        }
    }
}
#endif

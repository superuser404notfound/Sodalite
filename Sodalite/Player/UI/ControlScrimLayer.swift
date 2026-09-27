#if os(tvOS)
import SwiftUI
import UIKit

/// Sodalite#168: the transport's two scrims, faded by Core Animation instead of SwiftUI.
///
/// A SwiftUI opacity animation is stepped on the main thread, and hiding the controls tears the
/// whole transport down 0.3 s into the scrim's 0.7 s fade-out, so the scrim stood still for a
/// frame or two exactly there (seen on device at 23.976 Hz). A `CABasicAnimation` runs in the
/// render server and does not care what the main thread is doing.
struct ControlScrimLayer: UIViewRepresentable {
    let visible: Bool

    static let fadeInDuration: CFTimeInterval = 0.5
    static let fadeOutDuration: CFTimeInterval = 0.7

    func makeUIView(context: Context) -> ControlScrimView {
        ControlScrimView()
    }

    func updateUIView(_ view: ControlScrimView, context: Context) {
        view.setVisible(visible)
    }
}

final class ControlScrimView: UIView {
    private let bottom = CAGradientLayer()
    private let top = CAGradientLayer()
    private var visible: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        Self.apply(PlayerOverlayView.controlScrimStops, to: bottom)
        Self.apply(PlayerOverlayView.titleScrimStops, to: top)
        layer.addSublayer(bottom)
        layer.addSublayer(top)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height
        let bottomHeight = PlayerOverlayView.controlScrimHeight(playerHeight: height)
        bottom.frame = CGRect(x: 0, y: height - bottomHeight, width: bounds.width, height: bottomHeight)
        top.frame = CGRect(x: 0, y: 0, width: bounds.width,
                           height: PlayerOverlayView.titleScrimHeight(playerHeight: height))
        CATransaction.commit()
    }

    func setVisible(_ newValue: Bool) {
        guard newValue != visible else { return }
        let isFirst = visible == nil
        visible = newValue
        let target: Float = newValue ? 1 : 0
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = target
        guard !isFirst, current != target else { return }

        // A reversal mid-fade keeps the same rate instead of restarting the full length.
        let full = newValue ? ControlScrimLayer.fadeInDuration : ControlScrimLayer.fadeOutDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = target
        fade.duration = full * CFTimeInterval(abs(target - current))
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(fade, forKey: "fade")
    }

    private static func apply(_ stops: [Gradient.Stop], to gradient: CAGradientLayer) {
        gradient.colors = stops.map { UIColor($0.color).cgColor }
        gradient.locations = stops.map { NSNumber(value: Double($0.location)) }
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
}
#endif

import SwiftUI

extension View {
    /// Hides tvOS's own fast-scroll index (the column of dots UIKit draws at the trailing edge
    /// during a fast swipe) on the enclosing ScrollView. Apply it to that ScrollView's CONTENT.
    /// For a page that draws an index of its own, where the system one stacks a second rail
    /// beside it (Sodalite#203). No-op on iOS, which has no such index.
    func hidesSystemScrollIndex(_ hidden: Bool) -> some View {
        #if os(tvOS)
        background(SystemScrollIndexProbe(hidden: hidden).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct SystemScrollIndexProbe: UIViewRepresentable {
    let hidden: Bool

    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.hidesIndex = hidden
    }

    final class ProbeView: UIView {
        var hidesIndex = false { didSet { apply() } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            (ancestor as? UIScrollView)?.indexDisplayMode = hidesIndex ? .alwaysHidden : .automatic
        }
    }
}
#endif

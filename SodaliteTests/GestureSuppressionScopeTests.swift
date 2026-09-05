import Testing
import UIKit
@testable import Sodalite

/// #121: the player suppresses AVKit's own gesture recognizers on every layout pass, because AVKit
/// re-attaches them. The walk descended the whole view hierarchy, so it also switched off whatever
/// SwiftUI had installed inside our overlay host: the stats panel's scroll gesture, every button tap.
///
/// That is silent until a recognizer outlives the pass that killed it. SwiftUI re-creates its
/// recognizers on rebuild, so ordinary interaction repaired itself; a panel that is open and then
/// merely re-laid-out does not rebuild, and a device rotation is exactly that. The panel stayed on
/// screen, correctly positioned, reachable by hit testing, and inert.
///
/// The chrome walk next to it already skipped these subtrees. This pins that the gesture walk does
/// the same, since the two are only correct together.
@MainActor
struct GestureSuppressionScopeTests {

    /// A view carrying one recognizer, so a tree can be assembled out of named parts.
    private func view(_ recognizer: UIGestureRecognizer? = nil) -> UIView {
        let v = UIView()
        if let recognizer { v.addGestureRecognizer(recognizer) }
        return v
    }

    @Test("recognizers outside the owned subtrees are disabled")
    func avkitRecognizersAreDisabled() {
        let chromeGesture = UITapGestureRecognizer()
        let chrome = view(chromeGesture)
        let root = view()
        root.addSubview(chrome)

        PlayerHostController.suppressGestures(on: root, exclude: [], skippingSubtreesOf: [])
        #expect(chromeGesture.isEnabled == false)
    }

    /// The regression itself: a recognizer SwiftUI installed deep inside the overlay host, which the
    /// walk can never enumerate ahead of time because SwiftUI creates and replaces them as it likes.
    @Test("recognizers anywhere below an owned subtree survive")
    func overlayRecognizersSurvive() {
        let scrollGesture = UIPanGestureRecognizer()
        let buttonGesture = UITapGestureRecognizer()
        let scrollView = view(scrollGesture)
        let button = view(buttonGesture)
        scrollView.addSubview(button)
        let overlayHost = view()
        overlayHost.addSubview(scrollView)

        let chromeGesture = UITapGestureRecognizer()
        let chrome = view(chromeGesture)

        let root = view()
        root.addSubview(chrome)
        root.addSubview(overlayHost)

        PlayerHostController.suppressGestures(on: root, exclude: [],
                                              skippingSubtreesOf: [ObjectIdentifier(overlayHost)])

        #expect(scrollGesture.isEnabled, "the stats panel's scroll gesture must survive a layout pass")
        #expect(buttonGesture.isEnabled, "a button nested deeper must survive too")
        #expect(chromeGesture.isEnabled == false, "AVKit's own recognizers are still suppressed")
    }

    @Test("a recognizer on the skipped view itself is left alone")
    func recognizerOnTheSkippedRootSurvives() {
        let hostGesture = UITapGestureRecognizer()
        let overlayHost = view(hostGesture)
        let root = view()
        root.addSubview(overlayHost)

        PlayerHostController.suppressGestures(on: root, exclude: [],
                                              skippingSubtreesOf: [ObjectIdentifier(overlayHost)])
        #expect(hostGesture.isEnabled)
    }

    @Test("an explicitly excluded recognizer survives outside the owned subtrees")
    func excludedRecognizerSurvives() {
        let ours = UITapGestureRecognizer()
        let theirs = UITapGestureRecognizer()
        let shared = view(ours)
        shared.addGestureRecognizer(theirs)
        let root = view()
        root.addSubview(shared)

        PlayerHostController.suppressGestures(on: root, exclude: [ObjectIdentifier(ours)],
                                              skippingSubtreesOf: [])
        #expect(ours.isEnabled)
        #expect(theirs.isEnabled == false)
    }

    /// Two skipped subtrees, since the player owns both the render surface and the overlay host.
    @Test("several owned subtrees are all skipped in one walk")
    func multipleOwnedSubtreesAreSkipped() {
        let engineGesture = UITapGestureRecognizer()
        let overlayGesture = UITapGestureRecognizer()
        let chromeGesture = UITapGestureRecognizer()
        let engineSurface = view(engineGesture)
        let overlayHost = view(overlayGesture)
        let chrome = view(chromeGesture)

        let root = view()
        for sub in [engineSurface, overlayHost, chrome] { root.addSubview(sub) }

        PlayerHostController.suppressGestures(
            on: root, exclude: [],
            skippingSubtreesOf: [ObjectIdentifier(engineSurface), ObjectIdentifier(overlayHost)])

        #expect(engineGesture.isEnabled)
        #expect(overlayGesture.isEnabled)
        #expect(chromeGesture.isEnabled == false)
    }
}

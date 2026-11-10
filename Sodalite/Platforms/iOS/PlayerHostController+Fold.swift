import UIKit

/// iPhone Duo (iOS 27.1): standing half folded, the picture moves to the upright half and the controls
/// to the half on the table (see `FoldLayout`). The fold's reserved region is the source of truth for
/// the split; the hinge only tells us when to look again.
extension PlayerHostController {
    func installFoldObservation() {
        guard #available(iOS 27.1, *) else { return }
        let hinge = UIHingeInteraction { [weak self] _, _ in
            self?.view.setNeedsLayout()
        }
        view.addInteraction(hinge)
    }

    func updateFoldLayout() {
        guard #available(iOS 27.1, *) else { return }
        let divisions = FoldLayout.divisions(
            system: view.reservedRegions(kind: .division).filter(\.isActive).map(\.frame),
            bounds: view.bounds)
        let layout = FoldLayout.resolve(bounds: view.bounds, activeDivisions: divisions)
        if layout != viewModel.foldLayout {
            LogTap.shared.note("[Fold] layout=\(layout.map { "video=\($0.videoArea) panel=\($0.panelArea)" } ?? "full") divisions=\(divisions)")
            viewModel.foldLayout = layout
        }
        placeVideo(in: layout?.videoArea)
    }

    /// Moves AVKit's own views (picture, still frame and the software path's surface, which all live
    /// inside them) into the upright half, and back to where AVKit had them once the fold goes. Nothing
    /// is touched while the player is not split, so every other device keeps AVKit's layout as is.
    private func placeVideo(in area: CGRect?) {
        let avkitViews = view.subviews.filter { $0 !== overlayHostingView }
        guard let area else {
            for sub in avkitViews {
                // A view that filled the screen fills it again, at today's size: the device may have
                // turned while it stood folded.
                if let saved = foldSavedFrames[ObjectIdentifier(sub)] {
                    sub.frame = saved.filledScreen ? view.bounds : saved.frame
                }
            }
            foldSavedFrames.removeAll()
            return
        }
        for sub in avkitViews {
            let id = ObjectIdentifier(sub)
            if foldSavedFrames[id] == nil {
                foldSavedFrames[id] = (sub.frame, sub.frame == view.bounds)
            }
            if sub.frame != area { sub.frame = area }
        }
    }
}

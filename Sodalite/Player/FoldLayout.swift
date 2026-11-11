import CoreGraphics
import Foundation

/// How a folding screen (iPhone Duo) divides the player, worked out from the fold's reserved region.
///
/// Only one posture changes the player: the fold runs across the screen, so the device stands like a
/// small laptop ("tabletop"). The picture then moves to the upright half and the controls to the half
/// lying on the table. A fold running top to bottom (book posture) would cut through the picture, so
/// the player stays full screen there and the system's own handling applies.
///
/// Pure geometry so it can be tested without a device: the host passes its bounds and the frames of
/// the ACTIVE division regions, all in the same coordinate space.
struct FoldLayout: Equatable, Sendable {
    /// The upright half, above the fold.
    let videoArea: CGRect
    /// The half lying on the table, below the fold.
    let panelArea: CGRect

    /// Below this a half is too short to carry either the picture or the controls, so the player stays
    /// full screen (a region the system reports while the device is barely bent is not a posture).
    static let minimumHalfHeight: CGFloat = 160

    static func resolve(bounds: CGRect, activeDivisions: [CGRect]) -> FoldLayout? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // A fold across the screen is a band that is wider than tall and spans most of the width.
        let fold = activeDivisions.first { region in
            region.width > region.height
                && region.width >= bounds.width * 0.5
                && region.midY > bounds.minY
                && region.midY < bounds.maxY
        }
        guard let fold else { return nil }
        let video = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width, height: fold.minY - bounds.minY)
        let panel = CGRect(x: bounds.minX, y: fold.maxY,
                           width: bounds.width, height: bounds.maxY - fold.maxY)
        guard video.height >= minimumHalfHeight, panel.height >= minimumHalfHeight else { return nil }
        return FoldLayout(videoArea: video, panelArea: panel)
    }

    /// The active division frames to resolve against: the system's, or in a Debug build launched with
    /// `-SimulateTabletopFold YES` a 40 pt fold across any landscape screen (the middle by default;
    /// `-SimulateTabletopPortrait YES` allows portrait, where the outer display stays). Device Hub
    /// folds the simulator only by hand, so this is what lets a scripted run see the layout.
    static func divisions(system: [CGRect], bounds: CGRect) -> [CGRect] {
        #if DEBUG
        let defaults = UserDefaults.standard
        let orientationFits = bounds.width > bounds.height || defaults.bool(forKey: "SimulateTabletopPortrait")
        if defaults.bool(forKey: "SimulateTabletopFold"), orientationFits {
            // `-SimulateTabletopPanelHeight <pt>` sizes the lower half, so the outer display can stand
            // in for the inner one (about 314 pt below the fold in landscape).
            let panel = defaults.double(forKey: "SimulateTabletopPanelHeight")
            let foldTop = panel > 0 ? bounds.maxY - CGFloat(panel) - 40 : bounds.midY - 20
            return [CGRect(x: bounds.minX, y: foldTop, width: bounds.width, height: 40)]
        }
        #endif
        return system
    }
}

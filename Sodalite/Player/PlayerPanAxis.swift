import CoreGraphics

/// The axis a touchpad pan on the player commits to. A pan commits once its travel passes the
/// threshold AND one axis clearly dominates; a diagonal stays undecided and does nothing, because
/// the cheap mistake there was the expensive one: a down swipe toward the progress bar that drifted
/// sideways committed horizontal and scrubbed (or stepped to the neighbouring button) instead.
enum PlayerPanAxis: Equatable {
    case undetermined, horizontal, vertical

    /// Travel (pt) before a pan may commit; low enough to feel responsive.
    static let commitThreshold: CGFloat = 40
    /// How many times longer the winning axis must be than the other (2 = within ~27 degrees of it).
    static let dominance: CGFloat = 2

    static func resolve(translation t: CGPoint) -> PlayerPanAxis {
        let absX = abs(t.x)
        let absY = abs(t.y)
        guard max(absX, absY) >= commitThreshold else { return .undetermined }
        if absX >= absY * dominance { return .horizontal }
        if absY >= absX * dominance { return .vertical }
        return .undetermined
    }
}

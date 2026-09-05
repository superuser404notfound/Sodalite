#if os(tvOS)
import Foundation

/// Sodalite#115: on the 1st-generation Siri Remote the whole glass surface sits on ONE button, so a
/// click at its left or right edge reaches the app as a plain `.select` press, indistinguishable from
/// a click in the middle. UIKit will not close that gap: for an indirect touch `location(in:)` reports
/// the centre of the focused view no matter where the thumb is, because tvOS deliberately withholds
/// the finger position to keep pointer UIs off the platform. GameController does report it
/// (`GCMicroGamepad.reportsAbsoluteDpadValues`), and this is the rule that turns that reading into an
/// intent. Kept free of the framework so it is testable without the hardware.
enum SiriRemoteEdgeClick {
    /// How far out on the surface a click counts as an edge click, in the dpad's own -1...1 range.
    /// Not measured: no 1st-generation remote here to hold. The reporter's issue suggests a 15 to 20
    /// percent margin, this is the middle of that. `PlayerHostController` logs every reading against it
    /// so the value can be retuned from a real device's diagnostic log instead of from taste.
    static let edgeThreshold: Float = 0.65

    /// -1 for the left edge, +1 for the right, nil for anything that is not a horizontal edge click.
    static func direction(x: Float, y: Float) -> Int? {
        guard abs(x) >= edgeThreshold else { return nil }
        // A thumb in a corner clears the horizontal threshold as well; without this the top of the
        // surface would seek. Ambiguous (exactly diagonal) counts as not horizontal.
        guard abs(x) > abs(y) else { return nil }
        return x < 0 ? -1 : 1
    }
}
#endif

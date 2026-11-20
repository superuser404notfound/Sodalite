import CoreGraphics

/// Where a row of an adaptive grid starts, so a jump can scroll the vertical axis alone
/// (Sodalite#86). `scrollTo(id, anchor:)` aligns the item on both axes and slid the whole grid
/// sideways whenever the vertical offset had nowhere left to go.
struct GridScrollGeometry: Equatable {
    /// The grid's top in scroll-content coordinates.
    var gridTop: CGFloat
    var gridWidth: CGFloat
    var cellHeight: CGFloat
    var columnMinimum: CGFloat
    var spacing: CGFloat

    /// SwiftUI's `.adaptive` rule: as many minimum-width columns as fit, spacing between them.
    var columns: Int {
        Self.columns(width: gridWidth, minimum: columnMinimum, spacing: spacing)
    }

    static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 0 }
        return max(1, Int(((width + spacing) / (minimum + spacing)) + 0.001))
    }

    /// The column minimum that gives `width` as many columns as `width + reserved` would get with
    /// `base`. The alphabet rail takes 24pt on a phone, and that alone dropped a 402pt iPhone from
    /// three columns to two, so a big library looked emptier than a small one (Sodalite#240). The
    /// cards shrink by a few points instead.
    static func columnMinimum(base: CGFloat, width: CGFloat, reserved: CGFloat, spacing: CGFloat) -> CGFloat {
        guard reserved > 0, width > 0 else { return base }
        let wanted = columns(width: width + reserved, minimum: base, spacing: spacing)
        guard wanted > columns(width: width, minimum: base, spacing: spacing) else { return base }
        // A hair under the exact fit, so float rounding inside the grid can't lose the column.
        return min(base, (width - CGFloat(wanted - 1) * spacing) / CGFloat(wanted) - 0.01)
    }

    /// Top of the row holding the `position`-th visible cell; nil until the grid has been measured.
    func rowTop(forPosition position: Int) -> CGFloat? {
        guard columns > 0, cellHeight > 0 else { return nil }
        return gridTop + CGFloat(position / columns) * (cellHeight + spacing)
    }
}

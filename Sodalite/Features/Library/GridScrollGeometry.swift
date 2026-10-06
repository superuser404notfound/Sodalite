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
        guard gridWidth > 0, columnMinimum > 0 else { return 0 }
        return max(1, Int(((gridWidth + spacing) / (columnMinimum + spacing)) + 0.001))
    }

    /// Top of the row holding the `position`-th visible cell; nil until the grid has been measured.
    func rowTop(forPosition position: Int) -> CGFloat? {
        guard columns > 0, cellHeight > 0 else { return nil }
        return gridTop + CGFloat(position / columns) * (cellHeight + spacing)
    }
}

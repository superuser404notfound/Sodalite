import Testing
import UIKit
@testable import Sodalite

/// Sodalite#137 dropped the airtime line from a program block and gave the title the whole cell,
/// which only pays off while two headline lines actually fit: SwiftUI answers a vertical overflow by
/// silently rendering ONE line, so a row that is a point too short shows a truncated title and no
/// symptom anywhere near the cause.
///
/// Measured on the tvOS simulator, so these are the real font metrics rather than an approximation.
struct GuideProgramCellBudgetTests {

    /// `GuideProgramCellContent` insets itself 4pt top and bottom inside the row.
    private static let cellInset: CGFloat = 8

    @Test("two headline lines fit a tv guide row")
    func twoTitleLinesFitTheRow() {
        let line = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        let content = GuideMetrics.tv.rowHeight - Self.cellInset
        #expect(2 * line <= content)
    }

    /// The freed line is the whole point of the change: the old stack was one headline plus a
    /// caption, so the row was never sized for a second title line and it is close (90.70 of 92).
    @Test("the second title line costs more than the airtime line it replaced")
    func theSecondLineIsTheTighterFit() {
        let headline = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        let caption = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        #expect(2 * headline > headline + 2 + caption)
    }
}

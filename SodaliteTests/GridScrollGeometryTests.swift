import CoreGraphics
import Testing
@testable import Sodalite

struct GridScrollGeometryTests {
    private func geometry(width: CGFloat = 1600) -> GridScrollGeometry {
        GridScrollGeometry(gridTop: 400, gridWidth: width, cellHeight: 420, columnMinimum: 230, spacing: 50)
    }

    @Test func columnsFollowTheAdaptiveGridRule() {
        // floor((1600 + 50) / (230 + 50)) = 5
        #expect(geometry().columns == 5)
        // exactly six fit: 6 * 230 + 5 * 50 = 1630
        #expect(geometry(width: 1630).columns == 6)
    }

    @Test func offsetIsTheRowTop() {
        let g = geometry()
        #expect(g.rowTop(forPosition: 0) == 400)
        #expect(g.rowTop(forPosition: 4) == 400)
        #expect(g.rowTop(forPosition: 5) == 870)
        #expect(g.rowTop(forPosition: 12) == 1340)
    }

    @Test func unmeasuredGeometryHasNoOffset() {
        let g = GridScrollGeometry(gridTop: 0, gridWidth: 0, cellHeight: 0, columnMinimum: 230, spacing: 50)
        #expect(g.rowTop(forPosition: 3) == nil)
    }

    // Sodalite#240: iPhone 18 Pro, 402pt wide, 16pt insets, 24pt rail clearance, 108pt minimum.
    @Test func railDoesNotCostAColumn() {
        let width: CGFloat = 402 - 32 - 24
        #expect(GridScrollGeometry.columns(width: width, minimum: 108, spacing: 16) == 2)
        let minimum = GridScrollGeometry.columnMinimum(base: 108, width: width, reserved: 24, spacing: 16)
        #expect(minimum < 108 && minimum > 100)
        #expect(GridScrollGeometry.columns(width: width, minimum: minimum, spacing: 16) == 3)
    }

    @Test func minimumStaysWhenTheRailCostsNothing() {
        #expect(GridScrollGeometry.columnMinimum(base: 108, width: 370, reserved: 0, spacing: 16) == 108)
        // 1500 and 1548 both hold five 230pt columns.
        #expect(GridScrollGeometry.columnMinimum(base: 230, width: 1500, reserved: 48, spacing: 50) == 230)
        // Unmeasured grid keeps the base.
        #expect(GridScrollGeometry.columnMinimum(base: 108, width: 0, reserved: 24, spacing: 16) == 108)
    }
}

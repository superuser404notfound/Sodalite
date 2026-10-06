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
}

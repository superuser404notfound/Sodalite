import CoreGraphics
import Testing
@testable import Sodalite

@Suite("Fold layout (iPhone Duo tabletop)")
struct FoldLayoutTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test("A fold across the screen splits it at the region's edges")
    func horizontalFoldSplits() throws {
        let fold = CGRect(x: 0, y: 380, width: 1000, height: 40)
        let layout = try #require(FoldLayout.resolve(bounds: bounds, activeDivisions: [fold]))
        #expect(layout.videoArea == CGRect(x: 0, y: 0, width: 1000, height: 380))
        #expect(layout.panelArea == CGRect(x: 0, y: 420, width: 1000, height: 380))
    }

    @Test("A fold on a half point snaps outward to whole points")
    func fractionalFoldSnapsToWholePoints() throws {
        let fold = CGRect(x: 0, y: 455.5, width: 1000, height: 40)
        let layout = try #require(FoldLayout.resolve(bounds: bounds, activeDivisions: [fold]))
        #expect(layout.videoArea.maxY == 455)
        #expect(layout.panelArea.minY == 496)
        #expect(layout.panelArea.maxY == 800)
    }

    @Test("A fold running top to bottom keeps the player full screen")
    func verticalFoldIsIgnored() {
        let fold = CGRect(x: 480, y: 0, width: 40, height: 800)
        #expect(FoldLayout.resolve(bounds: bounds, activeDivisions: [fold]) == nil)
    }

    @Test("No active fold keeps the player full screen")
    func noFold() {
        #expect(FoldLayout.resolve(bounds: bounds, activeDivisions: []) == nil)
    }

    @Test("A fold too close to an edge leaves a half too short to use")
    func foldNearEdge() {
        let fold = CGRect(x: 0, y: 700, width: 1000, height: 40)
        #expect(FoldLayout.resolve(bounds: bounds, activeDivisions: [fold]) == nil)
    }

    @Test("A fold outside the bounds does not count")
    func foldOutside() {
        let fold = CGRect(x: 0, y: 900, width: 1000, height: 40)
        #expect(FoldLayout.resolve(bounds: bounds, activeDivisions: [fold]) == nil)
    }

    @Test("The horizontal fold is picked when another region is listed first")
    func picksHorizontal() throws {
        let vertical = CGRect(x: 480, y: 0, width: 40, height: 800)
        let horizontal = CGRect(x: 0, y: 380, width: 1000, height: 40)
        let layout = try #require(FoldLayout.resolve(bounds: bounds, activeDivisions: [vertical, horizontal]))
        #expect(layout.videoArea.height == 380)
    }
}

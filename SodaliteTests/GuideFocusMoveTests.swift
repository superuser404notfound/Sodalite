#if os(tvOS)
import Testing
import UIKit
@testable import Sodalite

/// Sodalite#221 retest: only Left and Right pick a time. The redirect serving a vertical move
/// arrives with no heading, and re-anchoring on it pulled a picked time earlier on every long block.
struct GuideFocusMoveTests {

    @Test("Left and Right inside the grid pick a time")
    func horizontalPicks() {
        #expect(GuideGridViewController.moveSetsAnchor(heading: .left, servedRedirect: false,
                                                       cameFromGrid: true))
        #expect(GuideGridViewController.moveSetsAnchor(heading: .right, servedRedirect: false,
                                                       cameFromGrid: true))
    }

    @Test("Up and Down keep the time")
    func verticalKeeps() {
        #expect(!GuideGridViewController.moveSetsAnchor(heading: .down, servedRedirect: false,
                                                        cameFromGrid: true))
        #expect(!GuideGridViewController.moveSetsAnchor(heading: .up, servedRedirect: false,
                                                        cameFromGrid: true))
    }

    @Test("the served redirect keeps the time although it carries no heading")
    func redirectKeeps() {
        #expect(!GuideGridViewController.moveSetsAnchor(heading: [], servedRedirect: true,
                                                        cameFromGrid: true))
    }

    @Test("a headingless update and an entry from outside the grid keep the time")
    func otherUpdatesKeep() {
        #expect(!GuideGridViewController.moveSetsAnchor(heading: [], servedRedirect: false,
                                                        cameFromGrid: true))
        #expect(!GuideGridViewController.moveSetsAnchor(heading: .right, servedRedirect: false,
                                                        cameFromGrid: false))
    }
}
#endif

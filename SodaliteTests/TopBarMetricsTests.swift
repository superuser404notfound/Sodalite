import Foundation
import Testing
@testable import Sodalite

/// The top bar stands where the system bar stood, so every page keeps the layout it was built
/// against. These are the numbers measured off the system bar in the tvOS 26 simulator.
struct TopBarMetricsTests {
    @Test func aTabRootStartsWhereItStartedUnderTheSystemBar() {
        #expect(TopBarMetrics.systemSafeTop + TopBarMetrics.contentInset == 157)
        #expect(TopBarMetrics.barTop == 46)
        #expect(TopBarMetrics.barHeight == 68)
    }

    @Test func theScrollCarriesTheBarFullyOffScreen() {
        #expect(TopBarMetrics.travel >= TopBarMetrics.barTop + TopBarMetrics.barHeight)
    }
}

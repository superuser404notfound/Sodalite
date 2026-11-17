import Testing
@testable import Sodalite

/// BRW-201 / BRW-R205: one definition of "Home is not the screen".
@MainActor
struct HomeVisibilityTests {
    @Test func homeIsTheScreenOnlyWhenNothingElseIs() {
        #expect(!HomeVisibility.isHidden(covered: false, heroPlayActive: false, pageShown: true))
    }

    @Test func eachCauseHidesHome() {
        #expect(HomeVisibility.isHidden(covered: true, heroPlayActive: false, pageShown: true))
        #expect(HomeVisibility.isHidden(covered: false, heroPlayActive: true, pageShown: true))
        #expect(HomeVisibility.isHidden(covered: false, heroPlayActive: false, pageShown: false))
    }
}

import Foundation
import Testing
@testable import Sodalite

struct AppTabDownloadsTests {
    @Test func theTabAppearsOnlyWithDownloads() {
        #if os(iOS)
        #expect(AppTab.probedTabs(hasLiveTV: false, hasMusic: false, hasDownloads: true).contains(.downloads))
        #endif
        #expect(!AppTab.probedTabs(hasLiveTV: false, hasMusic: false, hasDownloads: false).contains(.downloads))
        #expect(!AppTab.baseTabs.contains(.downloads))
    }
}

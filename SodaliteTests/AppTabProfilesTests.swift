import Foundation
import Testing
@testable import Sodalite

struct AppTabProfilesTests {
    @Test func theTabFollowsSettingsOnlyWithProfilesToSwitchTo() {
        let tabs = AppTab.probedTabs(hasLiveTV: true, hasMusic: true)
        #if os(tvOS)
        #expect(AppTab.withProfiles(tabs, hasProfiles: true) == tabs + [.profiles])
        #else
        #expect(AppTab.withProfiles(tabs, hasProfiles: true) == tabs)
        #endif
        #expect(AppTab.withProfiles(tabs, hasProfiles: false) == tabs)
    }

    @Test func theProbesAndTheHideListNeverCarryIt() {
        #expect(!AppTab.baseTabs.contains(.profiles))
        #expect(!AppTab.probedTabs(hasLiveTV: true, hasMusic: true, hasDownloads: true).contains(.profiles))
        #expect(!AppTab.hideableCases.contains(.profiles))
    }
}

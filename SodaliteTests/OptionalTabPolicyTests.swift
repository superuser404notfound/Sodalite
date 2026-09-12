import Testing
@testable import Sodalite

/// Sodalite#141: finishing "Add another profile" rebuilt the tvOS tab list twice, which throws the
/// Settings tab's navigation stack away (device-verified in Sodalite#62) and left the reporter on
/// the settings root with a navigation bar that took focus but would not move sideways.
///
/// The unit under test is the rebuild COUNT, so the scenarios below replay the two decisions in the
/// order TabRootView makes them and collect what would reach the bar.
struct OptionalTabPolicyTests {

    /// Every tab set a login completion would publish, in order. Empty means the bar is untouched.
    private func loginPublications(
        onScreen: [AppTab],
        probedServerID: String?,
        activeServerID: String?,
        hasLiveTV: Bool,
        hasMusic: Bool
    ) -> [[AppTab]] {
        var current = onScreen
        var published: [[AppTab]] = []
        if let dropped = OptionalTabPolicy.setToPublishBeforeLoginProbe(
            onScreen: current,
            probedServerID: probedServerID,
            activeServerID: activeServerID
        ) {
            current = dropped
            published.append(dropped)
        }
        if let probed = OptionalTabPolicy.setToPublishAfterProbe(
            onScreen: current,
            hasLiveTV: hasLiveTV,
            hasMusic: hasMusic
        ) {
            current = probed
            published.append(probed)
        }
        return published
    }

    private let full: [AppTab] = [.home, .liveTV, .catalog, .search, .music, .settings]

    // MARK: - The assembled sets

    @Test("the base set is every tab that does not depend on a server probe")
    func baseSet() {
        #expect(AppTab.baseTabs == [.home, .catalog, .search, .settings])
    }

    @Test("Live TV sits after Home, Music before Settings")
    func probedOrder() {
        #expect(AppTab.probedTabs(hasLiveTV: false, hasMusic: false) == [.home, .catalog, .search, .settings])
        #expect(AppTab.probedTabs(hasLiveTV: true, hasMusic: false) == [.home, .liveTV, .catalog, .search, .settings])
        #expect(AppTab.probedTabs(hasLiveTV: false, hasMusic: true) == [.home, .catalog, .search, .music, .settings])
        #expect(AppTab.probedTabs(hasLiveTV: true, hasMusic: true) == full)
    }

    // MARK: - Sodalite#141

    @Test("adding a profile on the server already probed rebuilds the bar zero times")
    func addProfileOnSameServerPublishesNothing() {
        // The reporter's server offers both optional libraries, so both tabs are on screen.
        let published = loginPublications(
            onScreen: full,
            probedServerID: "server-a",
            activeServerID: "server-a",
            hasLiveTV: true,
            hasMusic: true
        )
        #expect(published.isEmpty)
    }

    @Test("a same-server profile with fewer libraries costs one rebuild, not two")
    func narrowerProfilePublishesOnce() {
        // A profile without access to the music library is a real change and has to reach the bar,
        // but it must not be preceded by a teardown to the base set.
        let published = loginPublications(
            onScreen: full,
            probedServerID: "server-a",
            activeServerID: "server-a",
            hasLiveTV: true,
            hasMusic: false
        )
        #expect(published == [[.home, .liveTV, .catalog, .search, .settings]])
    }

    @Test("a login that landed on another server drops the stale tabs before probing")
    func addServerDropsStaleTabsFirst() {
        let published = loginPublications(
            onScreen: full,
            probedServerID: "server-a",
            activeServerID: "server-b",
            hasLiveTV: true,
            hasMusic: true
        )
        // The Live TV tab on screen points at a backend that is gone and crashes the EPG stack when
        // tapped, so it goes at once and comes back a round trip later.
        #expect(published == [AppTab.baseTabs, full])
    }

    @Test("nothing probed yet counts as another server")
    func firstLoginDropsFirst() {
        #expect(OptionalTabPolicy.setToPublishBeforeLoginProbe(
            onScreen: [.home, .liveTV, .catalog, .search, .settings],
            probedServerID: nil,
            activeServerID: "server-a"
        ) == AppTab.baseTabs)
    }

    @Test("a server change with nothing optional on screen still rebuilds nothing")
    func staleDropIsItselfDiffed() {
        #expect(OptionalTabPolicy.setToPublishBeforeLoginProbe(
            onScreen: AppTab.baseTabs,
            probedServerID: "server-a",
            activeServerID: "server-b"
        ) == nil)
    }

    // MARK: - Shared by all three probe sites

    @Test("a probe that confirms what is on screen publishes nothing")
    func unchangedProbeIsNoRebuild() {
        #expect(OptionalTabPolicy.setToPublishAfterProbe(
            onScreen: full,
            hasLiveTV: true,
            hasMusic: true
        ) == nil)
        #expect(OptionalTabPolicy.setToPublishAfterProbe(
            onScreen: AppTab.baseTabs,
            hasLiveTV: false,
            hasMusic: false
        ) == nil)
    }

    @Test("a probe that found a library publishes the whole set in one assignment")
    func changedProbePublishesOnce() {
        #expect(OptionalTabPolicy.setToPublishAfterProbe(
            onScreen: AppTab.baseTabs,
            hasLiveTV: true,
            hasMusic: true
        ) == full)
    }
}

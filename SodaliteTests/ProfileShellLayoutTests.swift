import Testing
@testable import Sodalite

@Suite("Profile switch and the tab shell")
struct ProfileShellLayoutTests {
    private let alice = ProfileKey(serverID: "s", userID: "alice")
    private let bob = ProfileKey(serverID: "s", userID: "bob")

    private func layout(_ profile: ProfileKey?, _ tabs: [AppTab], _ style: AppearancePreferences.NavigationStyle = .topBar) -> ProfileShellLayout {
        ProfileShellLayout(profile: profile, tabs: tabs, style: style)
    }

    @Test func aSwitchToTheSameLayoutStaysPut() {
        #expect(!ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home, .settings]), to: layout(bob, [.home, .settings])))
    }

    @Test func aSwitchToOtherTabsLandsOnHome() {
        #expect(ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home, .catalog, .settings]), to: layout(bob, [.home, .settings])))
    }

    @Test func aSwitchToAnotherStyleLandsOnHome() {
        #expect(ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home], .topBar), to: layout(bob, [.home], .sidebar)))
    }

    /// Hiding a tab inside one profile is landingTab's job, and signing in or out is not a switch.
    @Test func aSwitchThatChangesTheShellLandsOnHome() {
        #expect(ProfileShellLayout.landingTab(current: .settings, tabs: [.home, .liveTV, .catalog, .settings], landsOnHome: true) == .home)
    }

    @Test func hidingTheTabOnScreenLandsOnHome() {
        #expect(ProfileShellLayout.landingTab(current: .catalog, tabs: [.home, .settings], landsOnHome: false) == .home)
    }

    @Test func aChangeThatKeepsTheTabOnScreenStays() {
        #expect(ProfileShellLayout.landingTab(current: .settings, tabs: [.home, .settings], landsOnHome: false) == .settings)
    }

    @Test func onlyAChangeOfProfileCounts() {
        #expect(!ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home, .catalog]), to: layout(alice, [.home])))
        #expect(!ProfileShellLayout.switchLandsOnHome(from: layout(nil, [.home]), to: layout(alice, [.home, .catalog])))
    }

    // MARK: A switch whose tab set arrives later

    /// The switch and the shell do not have to move in the same update: the optional Live TV and
    /// Music tabs are published after two awaited probes, so a switch to a profile on another server
    /// settles the profile first and changes the tab set one or more updates later.

    @Test func aSwitchThatChangesTheShellAtOnceNeedsNoLatch() {
        let result = ProfileShellLayout.resolveSwitch(
            previous: layout(alice, [.home, .catalog, .settings]),
            current: layout(bob, [.home, .settings]),
            armedOrigin: nil
        )
        #expect(result.landsOnHome)
        #expect(result.origin == nil)
    }

    @Test func aSwitchWithNoShellChangeYetKeepsTheLayoutItLeft() {
        let before = layout(alice, [.home, .settings])
        let result = ProfileShellLayout.resolveSwitch(
            previous: before, current: layout(bob, [.home, .settings]), armedOrigin: nil
        )
        #expect(!result.landsOnHome)
        #expect(result.origin == before)
    }

    /// The point of the latch: the probe lands with the profile already settled, so the update it
    /// arrives in carries the same profile on both sides and only the pre-switch layout can judge it.
    @Test func aTabSetArrivingAfterTheSwitchStillLandsOnHome() {
        let before = layout(alice, [.home, .settings])
        let result = ProfileShellLayout.resolveSwitch(
            previous: layout(bob, [.home, .settings]),
            current: layout(bob, [.home, .liveTV, .settings]),
            armedOrigin: before
        )
        #expect(result.landsOnHome)
        #expect(result.origin == nil)
    }

    @Test func aLatchWaitsThroughAnUpdateThatChangesNothing() {
        let before = layout(alice, [.home, .settings])
        let result = ProfileShellLayout.resolveSwitch(
            previous: layout(bob, [.home, .settings]),
            current: layout(bob, [.home, .settings], .topBar),
            armedOrigin: before
        )
        #expect(!result.landsOnHome)
        #expect(result.origin == before)
    }

    /// A second switch replaces the latch rather than stacking on it.
    @Test func anotherSwitchRetargetsTheLatch() {
        let carol = ProfileKey(serverID: "s", userID: "carol")
        let stale = layout(alice, [.home, .catalog])
        let result = ProfileShellLayout.resolveSwitch(
            previous: layout(bob, [.home, .settings]),
            current: layout(carol, [.home, .settings]),
            armedOrigin: stale
        )
        #expect(!result.landsOnHome)
        #expect(result.origin == layout(bob, [.home, .settings]))
    }

    /// Signing out drops the latch instead of holding a comparison against a profile that is gone.
    @Test func signingOutClearsTheLatch() {
        let result = ProfileShellLayout.resolveSwitch(
            previous: layout(bob, [.home, .settings]),
            current: layout(nil, [.home]),
            armedOrigin: layout(alice, [.home, .settings])
        )
        #expect(!result.landsOnHome)
        #expect(result.origin == nil)
    }

    @Test func withNoLatchAnOrdinaryTabChangeIsNotASwitch() {
        let result = ProfileShellLayout.resolveSwitch(
            previous: layout(bob, [.home, .catalog]),
            current: layout(bob, [.home]),
            armedOrigin: nil
        )
        #expect(!result.landsOnHome)
        #expect(result.origin == nil)
    }

    // MARK: What a switch takes down (audit 2026-09-25, CS-1 / SESSION-7)

    /// The reported case: a parent's unlocked Parental Controls must not survive into the child.
    @Test func aSwitchIntoAGatedProfilePopsSettings() {
        #expect(ProfileShellLayout.switchResetsSettings(from: alice, to: bob, escapesGated: true))
    }

    /// Nothing on the stack was locked, so an add-profile login returns where it started (#141).
    @Test func aSwitchWithoutGatesKeepsSettings() {
        #expect(!ProfileShellLayout.switchResetsSettings(from: alice, to: bob, escapesGated: false))
    }

    /// A refreshed user object for the same profile, or signing in, is not a switch.
    @Test func onlyAChangeOfProfilePopsSettings() {
        #expect(!ProfileShellLayout.switchResetsSettings(from: alice, to: alice, escapesGated: true))
        #expect(!ProfileShellLayout.switchResetsSettings(from: nil, to: alice, escapesGated: true))
    }

    /// Live TV access and the music library are per user, and nothing else re-probes a same-server switch.
    @Test func aSameServerSwitchReprobesTheOptionalTabs() {
        #expect(ProfileShellLayout.switchReprobesOptionalTabs(from: alice, to: bob))
        #expect(!ProfileShellLayout.switchReprobesOptionalTabs(from: alice, to: alice))
    }

    /// Another server has its own probes, which also drop the stale set first.
    @Test func aServerChangeIsLeftToTheServerProbes() {
        let elsewhere = ProfileKey(serverID: "t", userID: "bob")
        #expect(!ProfileShellLayout.switchReprobesOptionalTabs(from: alice, to: elsewhere))
        #expect(!ProfileShellLayout.switchReprobesOptionalTabs(from: nil, to: alice))
    }
}

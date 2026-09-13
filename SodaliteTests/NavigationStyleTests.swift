import Testing
import Foundation
@testable import Sodalite

/// Sodalite#140: the tvOS shell can navigate from a sidebar instead of the bar across the top. The
/// choice is stored rather than probed, so an update never moves a viewer's navigation without
/// being asked, and a stored value from another platform or a future build cannot strand anyone.
@MainActor
struct NavigationStyleTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "NavigationStyleTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("the top bar is what an untouched install gets")
    func defaultIsTopBar() {
        let prefs = AppearancePreferences(store: defaults("default"))
        #expect(prefs.navigationStyle == .topBar)
    }

    @Test("the choice writes through to the store and survives a reload")
    func writeThrough() {
        let store = defaults("persist")
        let prefs = AppearancePreferences(store: store)
        prefs.navigationStyle = .sidebar

        #expect(AppearancePreferences(store: store).navigationStyle == .sidebar)

        prefs.navigationStyle = .topBar
        #expect(AppearancePreferences(store: store).navigationStyle == .topBar)
    }

    @Test("a value this build does not know falls back to the top bar")
    func unknownStoredValueFallsBack() {
        let store = defaults("unknown")
        store.set("holographicRail", forKey: "appearance.navigationStyle")
        #expect(AppearancePreferences(store: store).navigationStyle == .topBar)
    }

    @Test("both styles are offered, in the order the picker steps through them")
    func pickerOrder() {
        #expect(AppearancePreferences.NavigationStyle.allCases == [.topBar, .sidebar])
    }
}

import Testing
import Foundation
@testable import Sodalite

/// Sodalite#62: the navigation bar's tabs are the user's choice, except for the two that would
/// strand them. Hiding Catalog also has to take the other Seerr browse surfaces with it.
@MainActor
struct TabVisibilityTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "TabVisibilityTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test("Home and Settings are not hideable, the other four are")
    func hideableCases() {
        #expect(AppTab.hideableCases == [.liveTV, .music, .catalog, .search])
        #expect(AppTab.home.isHideable == false)
        #expect(AppTab.settings.isHideable == false)
    }

    @Test("nothing is hidden by default")
    func defaultValue() {
        let prefs = AppearancePreferences(store: defaults("defaults"))
        #expect(prefs.hiddenTabs.isEmpty)
        #expect(AppTab.allCases.allSatisfy { !prefs.isTabHidden($0) })
    }

    @Test("hiding writes through to the store and survives a reload")
    func writeThrough() {
        let store = defaults("persist")
        let prefs = AppearancePreferences(store: store)
        prefs.setTab(.catalog, hidden: true)
        prefs.setTab(.music, hidden: true)
        prefs.setTab(.music, hidden: false)

        let reloaded = AppearancePreferences(store: store)
        #expect(reloaded.isTabHidden(.catalog))
        #expect(!reloaded.isTabHidden(.music))
    }

    @Test("Home and Settings cannot be hidden, neither by the setter nor by a stored value")
    func nonHideableTabsStayVisible() {
        let store = defaults("nonHideable")
        let prefs = AppearancePreferences(store: store)
        prefs.setTab(.home, hidden: true)
        prefs.setTab(.settings, hidden: true)
        #expect(prefs.hiddenTabs.isEmpty)

        // A payload from a future build (or a hand-edited defaults plist) must not lock the user out.
        store.set([AppTab.home.rawValue, AppTab.settings.rawValue, AppTab.catalog.rawValue],
                  forKey: "appearance.hiddenTabs")
        let reloaded = AppearancePreferences(store: store)
        #expect(reloaded.hiddenTabs == [.catalog])
    }

    @Test("setHiddenTabs replaces the whole set and drops the non-hideable tabs")
    func setHiddenTabsFilters() {
        let prefs = AppearancePreferences(store: defaults("setAll"))
        prefs.setHiddenTabs([.catalog, .home, .settings, .music])
        #expect(prefs.hiddenTabs == [.catalog, .music])
    }

    /// Writing live changed the tab set under the open settings screen, and rebuilding the
    /// TabView's tab list drops the Settings tab's navigation stack: every toggle threw the user
    /// back to the settings root. The commit belongs on the way out.
    @Test("the settings screen commits on the way out, not on every toggle")
    func deferredCommit() throws {
        let source = try sourceFile("Sodalite/Features/Settings/TabVisibilitySettingsView.swift")
        #expect(source.contains(".onDisappear(perform: commit)"))
        #expect(source.contains("appearance.setHiddenTabs(draft)"))
        #expect(!source.contains("appearance.setTab("))
    }

    @Test("a payload without the field carries no opinion, so an old device cannot unhide tabs")
    func payloadOmitsFieldWhenAbsent() throws {
        let json = """
        {
          "schemaVersion": 3,
          "updatedAt": 0,
          "accentChoice": "systemBlue",
          "backgroundStyle": "graphiteGlass",
          "showContentLogos": true,
          "continueWatchingImage": "still",
          "largeCards": false,
          "nowPlayingUsesSeriesPoster": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let payload = try decoder.decode(AppearanceSettingsPayload.self, from: Data(json.utf8))
        #expect(payload.hiddenTabs == nil)
    }

    @Test("hidden tabs round-trip through the sync payload")
    func payloadRoundTrip() throws {
        let payload = AppearanceSettingsPayload(
            updatedAt: Date(timeIntervalSince1970: 1),
            accentChoice: "systemBlue",
            backgroundStyle: "graphiteGlass",
            showContentLogos: true,
            continueWatchingImage: "still",
            largeCards: false,
            nowPlayingUsesSeriesPoster: false,
            hiddenTabs: [AppTab.catalog.rawValue]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AppearanceSettingsPayload.self, from: data)
        #expect(decoded.hiddenTabs == [AppTab.catalog.rawValue])
        #expect(decoded.schemaVersion == 4)
    }

    @Test("Seerr browsing follows the Catalog tab, not just the connection")
    func seerrSurfacesFollowTheCatalogTab() {
        let appState = AppState()
        let prefs = AppearancePreferences(store: defaults("surfaces"))
        #expect(SeerrSurfacePolicy.browsingEnabled(appState: appState, appearance: prefs) == false)

        appState.activeSeerrServer = SeerrServer(url: URL(string: "https://seerr.example.com")!)
        appState.activeSeerrUser = SeerrUser(
            id: 1,
            email: nil,
            username: "family",
            displayName: nil,
            avatar: nil,
            userType: nil,
            requestCount: nil,
            permissions: nil
        )
        #expect(SeerrSurfacePolicy.browsingEnabled(appState: appState, appearance: prefs))

        prefs.setTab(.catalog, hidden: true)
        #expect(SeerrSurfacePolicy.browsingEnabled(appState: appState, appearance: prefs) == false)
    }

    @Test("the tab bar and the Seerr surfaces are wired to the preference")
    func callSitesWired() throws {
        let tabRoot = try sourceFile("Sodalite/App/TabRootView.swift")
        #expect(tabRoot.contains("appearance.isTabHidden"))

        let search = try sourceFile("Sodalite/Features/Search/SearchView.swift")
        #expect(search.contains("SeerrSurfacePolicy.browsingEnabled"))
        #expect(!search.contains("appState.isSeerrConnected ? dependencies.seerrSearchService"))

        let person = try sourceFile("Sodalite/Features/Detail/PersonDetailView.swift")
        #expect(!person.contains("SeerrSurfacePolicy.browsingEnabled"))
        #expect(person.contains("isSeerrConnected: appState.isSeerrConnected"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

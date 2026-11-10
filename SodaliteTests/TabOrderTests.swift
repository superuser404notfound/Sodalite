import Foundation
import Testing
@testable import Sodalite

/// Sodalite#235: the viewer's own order of the navigation tabs.
@Suite("Tab order", .serialized)
@MainActor
struct TabOrderTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "tabOrder.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func pin(_ id: String, _ name: String) -> ShellTab {
        .library(PinnedLibraryTab(library: JellyfinLibrary(
            id: id, name: name, collectionType: nil, imageTags: nil, serverID: "srv"
        )))
    }

    @Test("the reporter's bar: Search ahead of the libraries, Collections last")
    func reportersOrder() {
        let collections = pin("c", "Collections"), movies = pin("m", "Movies"), shows = pin("s", "TV Shows")
        let bar: [ShellTab] = [.home, collections, movies, shows, .search, .settings]
        let order = ["search", "library:srv|m", "library:srv|s", "library:srv|c"]
        #expect(TabOrder.arrange(bar, by: order) == [.home, .search, movies, shows, collections, .settings])
    }

    @Test("no order is the default bar")
    func emptyOrder() {
        let bar: [ShellTab] = [.home, .liveTV, .catalog, .search, .settings, .profiles]
        #expect(TabOrder.arrange(bar, by: []) == bar)
    }

    @Test("Home, Settings and the profile switcher never move, whatever the order names")
    func fixedTabs() {
        #expect(TabOrder.key(for: AppTab.home) == nil)
        #expect(TabOrder.key(for: AppTab.settings) == nil)
        #expect(TabOrder.key(for: AppTab.profiles) == nil)
        let bar: [ShellTab] = [.home, .catalog, .search, .settings, .profiles]
        let order = ["settings", "profiles", "home", "search", "catalog"]
        #expect(TabOrder.arrange(bar, by: order) == [.home, .search, .catalog, .settings, .profiles])
    }

    @Test("a tab the order does not name keeps its default slot")
    func unnamedTabKeepsItsSlot() {
        let bar: [ShellTab] = [.home, .liveTV, .catalog, .search, .settings]
        #expect(TabOrder.arrange(bar, by: ["search", "catalog"]) == [.home, .liveTV, .search, .catalog, .settings])
    }

    @Test("keys for tabs that are not on screen are ignored")
    func absentKeysIgnored() {
        let bar: [ShellTab] = [.home, .catalog, .search, .settings]
        let order = ["podcasts", "search", "liveTV", "library:other|x", "catalog"]
        #expect(TabOrder.arrange(bar, by: order) == [.home, .search, .catalog, .settings])
    }

    @Test("the order survives a relaunch per profile, unknown keys included")
    func persistence() {
        let defaults = scratch("persist")
        let order = ["search", "podcasts", "library:srv|m"]
        AppearancePreferences(store: defaults, scope: "srv:a").setTabOrder(order)
        #expect(AppearancePreferences(store: defaults, scope: "srv:a").tabOrder == order)
        #expect(AppearancePreferences(store: defaults, scope: "srv:b").tabOrder.isEmpty)
    }

    @Test("the profile record carries the order, and a record without it changes nothing")
    func syncPayload() {
        let source = AppearancePreferences(store: scratch("syncSource"), scope: "srv:a")
        source.setTabOrder(["search", "catalog"])
        let target = AppearancePreferences(store: scratch("syncTarget"), scope: "srv:a")
        var payload = ProfileAppearancePayload(collecting: source, stamp: .distantPast)
        payload.apply(to: target)
        #expect(target.tabOrder == ["search", "catalog"])

        payload.tabOrder = nil
        target.setTabOrder(["catalog"])
        payload.apply(to: target)
        #expect(target.tabOrder == ["catalog"])
    }
}

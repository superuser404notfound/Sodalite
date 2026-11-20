import Foundation
import Testing
@testable import Sodalite

/// Libraries pinned as tabs of their own (tvOS, Discord 2026-10-23).
@Suite("Library tabs", .serialized)
@MainActor
struct LibraryTabsTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "libraryTabs.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let movies = JellyfinLibrary(id: "lib1", name: "Movies", collectionType: "movies", imageTags: nil, serverID: "srv")

    @Test("a pin carries the library's identity and type")
    func pinIdentity() {
        let pin = PinnedLibraryTab(library: movies)
        #expect(pin.originKey == movies.originKey)
        #expect(pin.library.libraryType == .movies)
        #expect(pin.library.id == "lib1")
        #expect(ShellTab.library(pin).systemImage == "film")
    }

    @Test("pins survive a relaunch, in order, per profile")
    func persistence() {
        let defaults = scratch("persist")
        let shows = JellyfinLibrary(id: "lib2", name: "Shows", collectionType: "tvshows", imageTags: nil, serverID: "srv")
        let pins = [PinnedLibraryTab(library: shows), PinnedLibraryTab(library: movies)]
        AppearancePreferences(store: defaults, scope: "srv:a").setPinnedLibraryTabs(pins)
        #expect(AppearancePreferences(store: defaults, scope: "srv:a").pinnedLibraryTabs == pins)
        #expect(AppearancePreferences(store: defaults, scope: "srv:b").pinnedLibraryTabs.isEmpty)
    }

    @Test("the profile record carries pins, and a record without them changes nothing")
    func sync() {
        let defaults = scratch("sync")
        let source = AppearancePreferences(store: defaults, scope: "srv:a")
        source.setPinnedLibraryTabs([PinnedLibraryTab(library: movies)])
        let payload = ProfileAppearancePayload(collecting: source, stamp: .now)

        let target = AppearancePreferences(store: defaults, scope: "srv:b")
        payload.apply(to: target)
        #expect(target.pinnedLibraryTabs == source.pinnedLibraryTabs)

        var older = payload
        older.pinnedLibraryTabs = nil
        target.setPinnedLibraryTabs([])
        older.apply(to: target)
        #expect(target.pinnedLibraryTabs.isEmpty)
    }

    @Test("a library tab opens the grid its My Media tile opens")
    func gridQuery() {
        let movieQuery = MyMediaLibraries.gridQuery(for: movies, grouping: .system)
        #expect(movieQuery.parentID == "lib1")
        #expect(movieQuery.includeItemTypes == [.movie])

        let boxSets = JellyfinLibrary(id: "bs", name: "Collections", collectionType: "boxsets", imageTags: nil)
        #expect(MyMediaLibraries.gridQuery(for: boxSets, grouping: .system).parentID == nil)

        let home = JellyfinLibrary(id: "hv", name: "Home Videos", collectionType: "homevideos", imageTags: nil)
        #expect(MyMediaLibraries.gridQuery(for: home, grouping: .system).recursive == false)
    }
}

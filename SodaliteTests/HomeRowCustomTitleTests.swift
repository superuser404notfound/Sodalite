import Testing
import Foundation
@testable import Sodalite

/// A row's own heading (Customize Home) has to survive everything that rewrites the stored rows:
/// the lossy load, the library reconcile and the cloud payload, which is the stored JSON verbatim.
@MainActor
struct HomeRowCustomTitleTests {
    private static func scope() -> String { "test-customTitle-\(UUID().uuidString)" }

    @Test func titleSurvivesSaveAndLossyLoad() {
        let scope = Self.scope()
        var configs = HomeRowConfig.defaultConfig()
        let index = configs.firstIndex { $0.type == .latestMovies }!
        configs[index].customTitle = "Trending Movies"
        HomeRowConfig.saveToStorage(configs, scope: scope)

        let loaded = HomeRowConfig.loadFromStorage(scope: scope)
        #expect(loaded.first { $0.type == .latestMovies }?.customTitle == "Trending Movies")
        #expect(loaded.filter { $0.customTitle != nil }.count == 1)
    }

    @Test func storedConfigWithoutTheFieldLoadsWithoutTitle() throws {
        let scope = Self.scope()
        let legacy = #"[{"type":"latestMovies","isEnabled":true,"sortOrder":0}]"#
        HomeRowConfig.setRawConfigData(Data(legacy.utf8), scope: scope)
        let loaded = HomeRowConfig.loadFromStorage(scope: scope)
        #expect(loaded.first { $0.type == .latestMovies }?.customTitle == nil)
    }

    @Test func reconcileKeepsTitleOfPerLibraryRow() {
        let libraries = [
            JellyfinLibrary(id: "a", name: "Movies", collectionType: "movies", imageTags: nil),
            JellyfinLibrary(id: "b", name: "Trending Movies", collectionType: "movies", imageTags: nil),
        ]
        var configs = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        let index = configs.firstIndex { $0.libraryID == "b" }!
        configs[index].customTitle = "Trending"

        let again = HomeRowConfig.reconciled(stored: configs, libraries: libraries)
        #expect(again.first { $0.libraryID == "b" }?.customTitle == "Trending")
    }

    @Test func resetDropsTitles() {
        var configs = HomeRowConfig.defaultConfig()
        configs[0].customTitle = "Mine"
        #expect(HomeRowConfig.resetToDefault(current: configs).allSatisfy { $0.customTitle == nil })
    }

    @Test func sanitizedTitleTrimsCapsAndClears() {
        #expect(HomeRowConfig.sanitizedTitle("  Trending  ") == "Trending")
        #expect(HomeRowConfig.sanitizedTitle("   ") == nil)
        #expect(HomeRowConfig.sanitizedTitle(String(repeating: "x", count: 200))?.count
            == HomeRowConfig.maxCustomTitleLength)
    }

    @Test func traktListsAreNotRenamable() {
        #expect(!HomeRowConfig(type: .traktLists, isEnabled: true, sortOrder: 0).isRenamable)
        #expect(HomeRowConfig(type: .traktWatchlist, isEnabled: true, sortOrder: 0).isRenamable)
    }
}

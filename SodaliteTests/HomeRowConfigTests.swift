import Testing
import Foundation
@testable import Sodalite

/// A fresh install and the Customize "Reset to default" button must land on the same home page.
/// Both used to diverge on multi-library servers because only reconciliation applied the
/// per-library default; now both go through `applyingSplitDefault`. These tests pin that parity,
/// and that a saved layout never gets the default applied behind its back.
@MainActor
struct HomeRowConfigTests {
    private func library(_ id: String, _ name: String, _ type: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: name, collectionType: type, imageTags: nil)
    }

    /// Reconciling the fresh-install default against a multi-library server must equal what
    /// "Reset to default" produces for the same discovered libraries.
    @Test func freshInstallMatchesResetOnMultiLibraryServer() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("t1", "Shows", "tvshows"),
        ]
        let fresh = HomeRowConfig.reconciled(
            stored: HomeRowConfig.defaultConfig(), libraries: libraries, isFreshInstall: true
        )
        let reset = HomeRowConfig.resetToDefault(current: fresh)
        #expect(fresh == reset)
    }

    /// Single-library servers were already consistent; guard against regressing that.
    @Test func freshInstallMatchesResetOnSingleLibraryServer() {
        let libraries = [library("m1", "Movies", "movies")]
        let fresh = HomeRowConfig.reconciled(
            stored: HomeRowConfig.defaultConfig(), libraries: libraries, isFreshInstall: true
        )
        let reset = HomeRowConfig.resetToDefault(current: fresh)
        #expect(fresh == reset)
    }

    /// A type with several libraries opens on one row per library, standing where the aggregated
    /// row stood; the aggregated row goes off. A type with one library keeps the aggregated row.
    @Test func freshInstallSplitsATypeWithSeveralLibraries() {
        let libraries = [
            library("m1", "Movies", "movies"),
            library("m2", "TMDB Trending", "movies"),
            library("t1", "Shows", "tvshows"),
        ]
        let fresh = HomeRowConfig.reconciled(
            stored: HomeRowConfig.defaultConfig(), libraries: libraries, isFreshInstall: true
        )
        let ordered = fresh.sorted { $0.sortOrder < $1.sortOrder }

        #expect(fresh.first { $0.type == .latestMovies }?.isEnabled == false)
        #expect(fresh.first { $0.type == .latestShows }?.isEnabled == true)
        let perLibrary = fresh.filter { $0.type == .libraryLatest }
        #expect(perLibrary.map(\.libraryID) == ["m1", "m2"])
        #expect(perLibrary.allSatisfy { $0.isEnabled })

        let anchor = ordered.firstIndex { $0.type == .latestMovies }!
        #expect(ordered[anchor + 1].libraryID == "m1")
        #expect(ordered[anchor + 2].libraryID == "m2")
        #expect(ordered[anchor + 3].type == .latestShows)
        #expect(ordered.map(\.sortOrder) == Array(0..<ordered.count))
    }

    /// One movies and one shows library split nothing: the page is the plain default.
    @Test func freshInstallWithOneLibraryPerTypeKeepsTheAggregates() {
        let libraries = [library("m1", "Movies", "movies"), library("t1", "Shows", "tvshows")]
        let fresh = HomeRowConfig.reconciled(
            stored: HomeRowConfig.defaultConfig(), libraries: libraries, isFreshInstall: true
        )
        #expect(fresh == HomeRowConfig.defaultConfig())
    }

    /// A saved layout that meets a second library gets the new row switched off, so nothing on an
    /// existing Home moves.
    @Test func savedLayoutGetsNewPerLibraryRowsDisabled() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("t1", "Shows A", "tvshows"),
            library("t2", "Shows B", "tvshows"),
        ]
        let saved = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)

        #expect(saved.first { $0.type == .latestMovies }?.isEnabled == true)
        #expect(saved.first { $0.type == .latestShows }?.isEnabled == true)
        let perLibrary = saved.filter { $0.type == .libraryLatest }
        #expect(perLibrary.count == 4)
        #expect(perLibrary.allSatisfy { !$0.isEnabled })
    }

    /// The fresh layout is saved by its first reconcile, and every later load reconciles it as a
    /// saved layout; that pass must leave it alone.
    @Test func freshLayoutIsStableOnTheNextReconcile() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
        ]
        let fresh = HomeRowConfig.reconciled(
            stored: HomeRowConfig.defaultConfig(), libraries: libraries, isFreshInstall: true
        )
        #expect(HomeRowConfig.reconciled(stored: fresh, libraries: libraries) == fresh)
    }

    /// Vanished libraries drop their per-library row; surviving ones keep their user toggle. Three
    /// libraries of one type, so that removing one leaves two behind and the survivors keep earning
    /// their rows (with one left they would be retired as redundant instead).
    @Test func reconcileDropsVanishedLibraryRows() {
        let libraries = [
            library("m1", "Movies A", "movies"),
            library("m2", "Movies B", "movies"),
            library("m3", "Movies C", "movies"),
        ]
        var stored = HomeRowConfig.reconciled(stored: HomeRowConfig.defaultConfig(), libraries: libraries)
        // User enables one per-library row.
        if let idx = stored.firstIndex(where: { $0.type == .libraryLatest && $0.libraryID == "m1" }) {
            stored[idx].isEnabled = true
        }
        // One library is removed server-side.
        let after = HomeRowConfig.reconciled(stored: stored, libraries: Array(libraries.prefix(2)))
        let dynamic = after.filter { $0.type == .libraryLatest }
        #expect(dynamic.map(\.libraryID) == ["m1", "m2"])
        #expect(dynamic.first?.isEnabled == true)
    }

    /// A row type added in a later app version must reach users who already have a persisted
    /// config: reconciliation used to append only `.libraryLatest`, so a new static row was
    /// unreachable short of Reset to default.
    @Test func reconcileAppendsMissingStaticRowType() {
        var stored = HomeRowConfig.defaultConfig()
        stored.removeAll { $0.type == .topRatedMovies }
        #expect(!stored.contains { $0.type == .topRatedMovies })

        let after = HomeRowConfig.reconciled(stored: stored, libraries: [])

        let restored = after.first { $0.type == .topRatedMovies }
        #expect(restored != nil)
        #expect(restored?.isEnabled == HomeRowType.topRatedMovies.defaultEnabled)
    }

    /// The appended row must not disturb what the user configured: an off-by-default row they
    /// enabled stays enabled, and nobody's sortOrder shifts.
    @Test func reconcileAppendingPreservesExistingRowState() {
        var stored = HomeRowConfig.defaultConfig()
        stored.removeAll { $0.type == .topRatedMovies }
        if let idx = stored.firstIndex(where: { $0.type == .recentlyAdded }) {
            stored[idx].isEnabled = true
        }
        if let idx = stored.firstIndex(where: { $0.type == .favorites }) {
            stored[idx].isEnabled = false
        }
        let before = stored

        let after = HomeRowConfig.reconciled(stored: stored, libraries: [])

        for old in before {
            let survivor = after.first { $0.id == old.id }
            #expect(survivor?.isEnabled == old.isEnabled)
            #expect(survivor?.sortOrder == old.sortOrder)
        }
        // Appended at the end, after the highest existing sortOrder.
        let appended = after.first { $0.type == .topRatedMovies }
        #expect((appended?.sortOrder ?? -1) > (before.map(\.sortOrder).max() ?? -1))
    }

    /// Reconciliation runs on every load; a second pass over its own output must be a no-op,
    /// else the persisted config churns and sortOrder drifts on each launch.
    @Test func reconcileIsIdempotentAfterAppending() {
        var stored = HomeRowConfig.defaultConfig()
        stored.removeAll { $0.type == .topRatedMovies }
        let libraries = [library("m1", "Movies", "movies")]

        let once = HomeRowConfig.reconciled(stored: stored, libraries: libraries)
        let twice = HomeRowConfig.reconciled(stored: once, libraries: libraries)
        #expect(once == twice)
    }
}

import Foundation
import Testing
@testable import Sodalite

struct LibraryLayoutTests {
    private func lib(_ id: String, _ server: String, _ name: String = "L") -> JellyfinLibrary {
        var l = JellyfinLibrary(id: id, name: name, collectionType: "movies", imageTags: nil)
        l.serverID = server
        return l
    }

    private var libs: [JellyfinLibrary] { [lib("1", "a"), lib("2", "a"), lib("3", "b")] }

    @Test func emptyLayoutKeepsServerOrder() {
        let layout = LibraryLayout(entries: [])
        #expect(layout.ordered(libs, fallbackServerID: "a").map(\.id) == ["1", "2", "3"])
        #expect(layout.visible(libs, fallbackServerID: "a").map(\.id) == ["1", "2", "3"])
    }

    @Test func storedOrderWinsAndNewLibrariesAppend() {
        let layout = LibraryLayout(entries: [.init(serverID: "b", libraryID: "3", isHidden: false),
                                             .init(serverID: "a", libraryID: "1", isHidden: false)])
        #expect(layout.ordered(libs, fallbackServerID: "a").map(\.id) == ["3", "1", "2"])
    }

    @Test func hiddenLeavesVisibleButStaysOrdered() {
        let layout = LibraryLayout(entries: []).toggling(lib("2", "a"), in: libs, fallbackServerID: "a")
        #expect(layout.visible(libs, fallbackServerID: "a").map(\.id) == ["1", "3"])
        #expect(layout.ordered(libs, fallbackServerID: "a").map(\.id) == ["1", "2", "3"])
        #expect(layout.isHidden(lib("2", "a"), fallbackServerID: "a"))
        #expect(!layout.toggling(lib("2", "a"), in: libs, fallbackServerID: "a").isHidden(lib("2", "a"), fallbackServerID: "a"))
    }

    @Test func sameIDOnTwoServersAreTwoEntries() {
        let twins = [lib("x", "a"), lib("x", "b")]
        let layout = LibraryLayout(entries: []).toggling(lib("x", "b"), in: twins, fallbackServerID: "a")
        #expect(layout.visible(twins, fallbackServerID: "a").map(\.serverID) == ["a"])
    }

    @Test func movingReordersAmongVisible() {
        let layout = LibraryLayout(entries: []).moving(lib("3", "b"), toIndexAmongVisible: 0, in: libs, fallbackServerID: "a")
        #expect(layout.ordered(libs, fallbackServerID: "a").map(\.id) == ["3", "1", "2"])
    }

    @Test func movingKeepsEntriesOfAbsentLibraries() {
        let stored = LibraryLayout(entries: [.init(serverID: "c", libraryID: "9", isHidden: true),
                                             .init(serverID: "a", libraryID: "1", isHidden: false),
                                             .init(serverID: "a", libraryID: "2", isHidden: false)])
        let present = [lib("1", "a"), lib("2", "a")]
        let moved = stored.moving(lib("2", "a"), toIndexAmongVisible: 0, in: present, fallbackServerID: "a")
        #expect(moved.entries.contains(.init(serverID: "c", libraryID: "9", isHidden: true)))
        #expect(moved.ordered(present, fallbackServerID: "a").map(\.id) == ["2", "1"])
    }

    @Test func sharedIDRowStaysWhileOneCopyIsVisible() {
        let twins = [lib("x", "a"), lib("x", "b")]
        let oneHidden = LibraryLayout(entries: []).toggling(lib("x", "b"), in: twins, fallbackServerID: "a")
        #expect(!oneHidden.hidesLatestRow(libraryID: "x"))
        let bothHidden = oneHidden.toggling(lib("x", "a"), in: twins, fallbackServerID: "a")
        #expect(bothHidden.hidesLatestRow(libraryID: "x"))
        #expect(!LibraryLayout(entries: []).hidesLatestRow(libraryID: "x"))
    }

    @Test func storageRoundTripsPerScope() {
        let defaults = UserDefaults(suiteName: "layout-\(UUID())")!
        let layout = LibraryLayout(entries: [.init(serverID: "a", libraryID: "1", isHidden: true)])
        layout.save(scope: "s1", defaults: defaults)
        #expect(LibraryLayout.load(scope: "s1", defaults: defaults) == layout)
        #expect(LibraryLayout.load(scope: "s2", defaults: defaults).entries.isEmpty)
        LibraryLayout.clear(scope: "s1", defaults: defaults)
        #expect(LibraryLayout.load(scope: "s1", defaults: defaults).entries.isEmpty)
    }
}

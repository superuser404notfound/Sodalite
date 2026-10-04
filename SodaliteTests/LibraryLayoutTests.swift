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

    @Test func homeRecordCarriesTheLayout() {
        let scope = "layout-sync-\(UUID())"
        defer { LibraryLayout.clear(scope: scope) }
        LibraryLayout(entries: [.init(serverID: "a", libraryID: "1", isHidden: true)]).save(scope: scope)
        let payload = ProfileHomeStore.collect(scope: scope, stamp: Date())
        LibraryLayout.clear(scope: scope)
        ProfileHomeStore.apply(payload, scope: scope)
        #expect(LibraryLayout.load(scope: scope).entries == [.init(serverID: "a", libraryID: "1", isHidden: true)])
    }

    @Test func olderRecordLeavesLayoutAlone() throws {
        let scope = "layout-old-\(UUID())"
        defer { LibraryLayout.clear(scope: scope) }
        let local = LibraryLayout(entries: [.init(serverID: "a", libraryID: "1", isHidden: true)])
        local.save(scope: scope)
        let old = try JSONDecoder().decode(ProfileHomePayload.self, from: Data(
            #"{"schemaVersion":1,"updatedAt":0,"mergeCWNextUp":false,"rewatchNextUp":false,"collectionGrouping":"system","librarySorts":{}}"#.utf8))
        #expect(old.libraryLayoutJSON == nil)
        ProfileHomeStore.apply(old, scope: scope)
        #expect(LibraryLayout.load(scope: scope) == local)
    }

    final class FakeLibraries: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var libraries: [JellyfinLibrary] = []
        var delay: Duration = .zero
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return libraries
        }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func bare(_ id: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: "movies", imageTags: nil)
    }

    @MainActor
    @Test func slowSecondaryMakesTheListIncomplete() async throws {
        let a = FakeLibraries(); a.libraries = [bare("1")]
        let b = FakeLibraries(); b.libraries = [bare("2")]
        let sources = [HomeSource(serverID: "a", serverName: "A", userID: "u", libraryService: a, isActive: true),
                       HomeSource(serverID: "b", serverName: "B", userID: "u", libraryService: b, isActive: false)]
        let fast = try #require(await CustomizeLibraryList.fetch(sources, secondaryDeadline: .seconds(1)))
        #expect(fast.libraries.map(\.id) == ["1", "2"])
        #expect(fast.libraries.map(\.serverID) == ["a", "b"])
        #expect(fast.complete)
        b.delay = .seconds(5)
        let slow = try #require(await CustomizeLibraryList.fetch(sources, secondaryDeadline: .milliseconds(200)))
        #expect(slow.libraries.map(\.id) == ["1"])
        #expect(!slow.complete)
    }

    @MainActor
    @Test func customizeLabelsOnlyDuplicateNamesAcrossServers() {
        let fake = FakeLibraries()
        let sources = [HomeSource(serverID: "a", serverName: "Wohnzimmer", userID: "u", libraryService: fake, isActive: true),
                       HomeSource(serverID: "b", serverName: "Keller", userID: "u", libraryService: fake, isActive: false)]
        let libs = [lib("1", "a", "Filme"), lib("2", "b", "filme"), lib("3", "b", "Serien")]
        #expect(CustomizeLibraryList.serverLabel(for: libs[0], in: libs, sources: sources) == "Wohnzimmer")
        #expect(CustomizeLibraryList.serverLabel(for: libs[1], in: libs, sources: sources) == "Keller")
        #expect(CustomizeLibraryList.serverLabel(for: libs[2], in: libs, sources: sources) == nil)
        #expect(CustomizeLibraryList.serverLabel(for: libs[0], in: libs, sources: Array(sources.prefix(1))) == nil)
    }

    // Review finding 1: a reset must travel, or another device pushes the old layout back.
    @Test func aResetReachesTheOtherDevices() {
        let scope = "layout-reset-\(UUID())"
        let other = "layout-reset-other-\(UUID())"
        defer { LibraryLayout.clear(scope: scope); LibraryLayout.clear(scope: other) }
        LibraryLayout(entries: [.init(serverID: "a", libraryID: "1", isHidden: true)]).save(scope: scope)
        LibraryLayout(entries: [.init(serverID: "a", libraryID: "1", isHidden: true)]).save(scope: other)
        LibraryLayout.reset(scope: scope)
        ProfileHomeStore.apply(ProfileHomeStore.collect(scope: scope, stamp: Date()), scope: other)
        #expect(LibraryLayout.load(scope: other).entries.isEmpty)
    }
}

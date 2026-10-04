import Foundation
import Testing
@testable import Sodalite

/// Findings from the Phase 2 branch review (Sodalite#85).
@Suite(.serialized)
@MainActor
struct CombinedHomeReviewFixTests {
    final class SlowLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var libraries: [JellyfinLibrary] = []
        var librariesDelay: Duration = .zero
        var librariesFail = false
        var latest: [JellyfinItem] = []
        var latestCalls = 0
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            if librariesDelay > .zero { try? await Task.sleep(for: librariesDelay) }
            if librariesFail { throw URLError(.timedOut) }
            return libraries
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            latestCalls += 1
            return latest
        }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func library(_ id: String, _ name: String, type: String = "movies", server: String? = nil) -> JellyfinLibrary {
        var l = JellyfinLibrary(id: id, name: name, collectionType: type, imageTags: nil)
        l.serverID = server
        return l
    }

    private func model(_ a: SlowLibrary, _ b: SlowLibrary?, deadline: Duration = .milliseconds(300)) -> HomeViewModel {
        let suffix = UUID().uuidString
        var sources = [HomeSource(serverID: "a-\(suffix)", serverName: "A", userID: "u-a", libraryService: a, isActive: true)]
        if let b { sources.append(HomeSource(serverID: "b-\(suffix)", serverName: "B", userID: "u-b", libraryService: b, isActive: false)) }
        let vm = HomeViewModel(
            libraryService: a,
            imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
            userID: "u-a", serverID: sources[0].serverID, sources: sources)
        vm.secondaryDeadline = deadline
        return vm
    }

    /// C1: a secondary whose library list hangs must not hold the load past its deadline.
    @Test func hangingSecondaryLibrariesDoNotHoldTheLoad() async {
        let a = SlowLibrary(); a.libraries = [library("la", "Movies")]
        let b = SlowLibrary(); b.librariesDelay = .seconds(6)
        let vm = model(a, b)
        let clock = ContinuousClock()
        let start = clock.now
        await vm.loadContent()
        #expect(clock.now - start < .seconds(3))
        #expect(vm.myMediaLibraries.map(\.id) == ["la"])
        #expect(vm.unreachableServerNames == ["B"])
    }

    /// I1: with one server a per-library row does not wait for the library list.
    @Test func singleServerLibraryRowDoesNotWaitForLibraries() async {
        let a = SlowLibrary(); a.librariesDelay = .seconds(6)
        let vm = model(a, nil)
        vm.librariesTasks[vm.sources[0].serverID] = Task { try? await a.getLibraries(userID: "u-a") }
        let config = HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 0, libraryID: "la", libraryName: "Movies", collectionType: "movies")
        let clock = ContinuousClock()
        let start = clock.now
        _ = await vm.fetchAcrossSources(config)
        #expect(clock.now - start < .seconds(2))
        #expect(a.latestCalls == 1)
    }

    /// I2: a secondary that did not answer keeps its per-library rows.
    @Test func incompleteLibraryListKeepsTheMissingServersRows() async {
        let a = SlowLibrary(); a.libraries = [library("la1", "Movies"), library("la2", "Kids")]
        let b = SlowLibrary(); b.librariesFail = true
        let vm = model(a, b)
        let kept = HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 50, libraryID: "lb-anime", libraryName: "Anime", collectionType: "movies")
        vm.rowConfigs = HomeRowConfig.defaultConfig() + [kept]
        await vm.loadContent()
        #expect(vm.rowConfigs.contains { $0.libraryID == "lb-anime" && $0.isEnabled })
    }

    /// I3: a revision for a session this Home was not built for is not this Home's business.
    @Test func sourcesForAnotherIdentityAreIgnored() async {
        let a = SlowLibrary()
        let vm = model(a, nil)
        let foreign = [HomeSource(serverID: "other", serverName: "O", userID: "u-o", libraryService: a, isActive: true)]
        #expect(!vm.acceptsSources(foreign))
        let same = [HomeSource(serverID: vm.serverID, serverName: "A", userID: vm.userID, libraryService: a, isActive: true),
                    HomeSource(serverID: "b", serverName: "B", userID: "u-b", libraryService: a, isActive: false)]
        #expect(vm.acceptsSources(same))
    }

    /// I4: a library grid opened from My Media belongs to the library's own server.
    @Test func libraryGridBelongsToTheLibrarysServer() {
        let a = SlowLibrary()
        let vm = model(a, SlowLibrary())
        let lb = library("lb", "Movies", server: vm.sources[1].serverID)
        #expect(vm.gridIdentity(forLibrary: lb) == CacheIdentity(serverID: vm.sources[1].serverID, userID: "u-b"))
        let la = library("la", "Movies", server: vm.sources[0].serverID)
        #expect(vm.gridIdentity(forLibrary: la) == vm.cacheIdentity)
    }

    /// I5: two servers whose library ids collide (same path, same hash) feed one merged row.
    @Test func collidingLibraryIdsMergeIntoOneRow() async throws {
        let a = SlowLibrary(); a.libraries = [library("same", "Movies")]
        a.latest = [try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"a1","Name":"a1","Type":"Movie","ServerId":"x"}"#.utf8))]
        let b = SlowLibrary(); b.libraries = [library("same", "Movies")]
        b.latest = [try JSONDecoder().decode(JellyfinItem.self, from: Data(#"{"Id":"b1","Name":"b1","Type":"Movie","ServerId":"y"}"#.utf8))]
        let vm = model(a, b)
        await vm.loadContent()
        let config = HomeRowConfig(type: .libraryLatest, isEnabled: true, sortOrder: 0, libraryID: "same", libraryName: "Movies", collectionType: "movies")
        let rows = await vm.fetchAcrossSources(config)
        #expect(rows.count == 2)
        #expect(vm.serverLabel(forRow: HomeRowData(type: .libraryLatest, items: [], libraryID: "same", libraryName: "Movies")) == nil)
    }

    /// I6: moving the anchor inside the same set keeps the combined cache slot.
    @Test func combinedSlotIgnoresWhichServerIsActive() {
        let s = SlowLibrary()
        let one = [HomeSource(serverID: "a", serverName: "A", userID: "u-a", libraryService: s, isActive: true),
                   HomeSource(serverID: "b", serverName: "B", userID: "u-b", libraryService: s, isActive: false)]
        let other = [HomeSource(serverID: "b", serverName: "B", userID: "u-b", libraryService: s, isActive: true),
                     HomeSource(serverID: "a", serverName: "A", userID: "u-a", libraryService: s, isActive: false)]
        #expect(HomeViewModel.combinedIdentity(for: one, userID: "u-a") == HomeViewModel.combinedIdentity(for: other, userID: "u-b"))
    }

    /// I7: a profile seeded from another does not inherit Combine servers.
    @Test func seedingAProfileLeavesCombineServersAlone() {
        let source = "srv-s:u-\(UUID().uuidString)"
        let target = "srv-t:u-\(UUID().uuidString)"
        let prefs = CombinedServersPreferences(defaults: .standard)
        prefs.setEnabled(true, scope: source)
        prefs.setExcluded(["q"], scope: source)
        defer { prefs.setEnabled(false, scope: source); prefs.setExcluded([], scope: source) }
        ProfileHomeStore.copy(fromScope: source, toScope: target)
        #expect(!prefs.isEnabled(scope: target))
        #expect(prefs.excludedServerIDs(scope: target).isEmpty)
    }
}

import Foundation
import Testing
@testable import Sodalite

@Suite(.serialized)
@MainActor
struct CombinedTagRowTests {
    final class GenreLibrary: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        var genres: [NamedItem] = []
        var sample: JellyfinItem?
        var genreItems: [JellyfinItem] = []
        func getGenres(userID: String) async throws -> [NamedItem] { genres }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            if query.limit == 1 { return .init(items: sample.map { [$0] } ?? [], totalRecordCount: sample == nil ? 0 : 1) }
            return .init(items: genreItems, totalRecordCount: genreItems.count)
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func named(_ id: String, _ name: String) throws -> NamedItem {
        try JSONDecoder().decode(NamedItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(name)"}"#.utf8))
    }

    private func movie(_ id: String, server: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","ServerId":"\#(server)","ImageTags":{"Primary":"p"}}"#.utf8))
    }

    private func model(_ a: GenreLibrary, _ b: GenreLibrary) -> HomeViewModel {
        let suffix = UUID().uuidString
        let sources = [HomeSource(serverID: "a-\(suffix)", serverName: "A", userID: "u-a", libraryService: a, isActive: true),
                       HomeSource(serverID: "b-\(suffix)", serverName: "B", userID: "u-b", libraryService: b, isActive: false)]
        let vm = HomeViewModel(libraryService: a,
                               imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
                               userID: "u-a", serverID: sources[0].serverID, sources: sources)
        vm.secondaryDeadline = .milliseconds(300)
        return vm
    }

    @Test func genreOnlyOnSecondaryAppearsAndCaches() async throws {
        let a = GenreLibrary(); a.genres = [try named("g1", "Drama")]; a.sample = try movie("a1", server: "a")
        let b = GenreLibrary(); b.genres = [try named("g2", "Horror"), try named("g3", "drama")]; b.sample = try movie("b1", server: "b")
        b.genreItems = [try movie("b9", server: "b")]
        let vm = model(a, b)
        let row = await vm.loadTagRow(type: .genres)
        #expect(Set(row?.tags.map { $0.name.lowercased() } ?? []) == ["drama", "horror"])

        if let row { vm.tagRows = [row] }
        await HomeViewModel.runGenreCaches { vm }
        let cached = FilterCache.shared.homeFilterItems(filterKey: FilterCacheKey.Home.genre(name: "Horror"), identity: vm.feedIdentity)
        #expect(cached?.map(\.id) == ["b9"])
    }

    @Test func oneSourceKeepsTodaysTagRow() async throws {
        let a = GenreLibrary(); a.genres = [try named("g1", "Drama")]; a.sample = try movie("a1", server: "a")
        let vm = HomeViewModel(libraryService: a,
                               imageService: JellyfinImageService(baseURLProvider: { URL(string: "http://a.lan") }),
                               userID: "u-a", serverID: "a-\(UUID().uuidString)")
        let row = await vm.loadTagRow(type: .genres)
        #expect(row?.tags.map(\.name) == ["Drama"])
    }
}

import Testing
import Foundation
@testable import Sodalite

/// The Latest Shows row and the library list it needs.
///
/// Jellyfin 12 answers `/Items/Latest` from two different implementations. With a `ParentId` on a
/// tvshows library it groups in SQL, one entry per series, and hands back a Season, a Series or a
/// bare Episode depending on what arrived. Without one it falls through to the old path, which
/// scans the newest `Limit * 2` items across every library and groups them in memory: one bulk
/// import is enough to fill that window, and the row collapses to the handful of series inside it.
///
/// So the row must never ask the untyped aggregate just because the library list has not landed
/// yet, and the entries it does get back must all end up as the series the row's title promises.
@MainActor
struct HomeLatestShowsRowTests {

    final class RecordingService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        struct LatestCall: Sendable, Equatable {
            let parentID: String?
            let includeItemTypes: [ItemType]?
            let limit: Int
        }

        private let lock = NSLock()
        private var calls: [LatestCall] = []
        var latestCalls: [LatestCall] { lock.withLock { calls } }

        /// Long enough that a row reading `myMediaLibraries` off the view model could not have seen
        /// it filled, which is the whole reported defect.
        var librariesDelay: Duration = .milliseconds(150)
        var libraries: [JellyfinLibrary] = []
        /// What the ParentId-scoped shows query answers.
        var showsLatest: [JellyfinItem] = []
        /// What the batched `Ids=` fold lookup can resolve.
        var itemsByID: [String: JellyfinItem] = [:]

        struct Unused: Error {}

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            try? await Task.sleep(for: librariesDelay)
            return libraries
        }

        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            lock.withLock {
                calls.append(LatestCall(parentID: parentID, includeItemTypes: includeItemTypes, limit: limit))
            }
            guard parentID != nil, includeItemTypes == nil else { return [] }
            return showsLatest
        }

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            guard let ids = query.ids else { throw Unused() }
            let items = ids.compactMap { itemsByID[$0] }
            return JellyfinItemsResponse(items: items, totalRecordCount: items.count)
        }

        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            throw Unused()
        }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
    }

    private static func item(_ json: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    private func makeViewModel(service: RecordingService) -> (HomeViewModel, String) {
        let serverID = "latestshows-\(UUID().uuidString)"
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: serverID
        )
        return (vm, serverID)
    }

    private func forget(serverID: String) {
        UserDefaults.standard.removeObject(forKey: "homeRowConfigs.\(serverID)")
    }

    private static let showLibrary = JellyfinLibrary(
        id: "lib-tv",
        name: "Serien",
        collectionType: "tvshows",
        imageTags: nil
    )

    @Test("the shows row asks the library, not the aggregate, on the first load of a session")
    func showsRowWaitsForTheLibraryList() async throws {
        let service = RecordingService()
        service.libraries = [Self.showLibrary]
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let calls = service.latestCalls
        #expect(calls.contains { $0.parentID == "lib-tv" && $0.includeItemTypes == nil },
                "the row never scoped its Latest query to the shows library: \(calls)")
        #expect(!calls.contains { $0.parentID == nil && $0.includeItemTypes == [.series, .episode] },
                "the row fell back to the untyped aggregate while the library list was reachable: \(calls)")
    }

    /// The failure path keeps the aggregate: a server that will not name its libraries still gets a
    /// row, imprecise but not empty.
    @Test("a library list that never arrives still leaves the aggregate fallback")
    func failedLibraryListKeepsTheAggregate() async throws {
        let service = RecordingService()
        service.libraries = []
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        #expect(service.latestCalls.contains { $0.parentID == nil && $0.includeItemTypes == [.series, .episode] },
                "no aggregate query went out for a server with no shows library: \(service.latestCalls)")
    }

    @Test("season and episode entries both fold into their series")
    func seasonsFoldIntoSeries() async throws {
        let service = RecordingService()
        service.libraries = [Self.showLibrary]
        service.showsLatest = [
            try Self.item(#"{"Id":"season-4","Name":"Staffel 4","Type":"Season","SeriesId":"series-discounter","SeriesName":"Die Discounter"}"#),
            try Self.item(#"{"Id":"ep-1","Name":"Folge 1","Type":"Episode","SeriesId":"series-cat","SeriesName":"Simon's Cat"}"#),
            try Self.item(#"{"Id":"series-bluey","Name":"Bluey","Type":"Series"}"#),
        ]
        service.itemsByID = [
            "series-discounter": try Self.item(#"{"Id":"series-discounter","Name":"Die Discounter","Type":"Series"}"#),
            "series-cat": try Self.item(#"{"Id":"series-cat","Name":"Simon's Cat","Type":"Series"}"#),
        ]
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let row = vm.rows.first { $0.type == .latestShows }
        #expect(row?.items.map(\.id) == ["series-discounter", "series-cat", "series-bluey"],
                "the row did not fold onto series: \(row?.items.map { "\($0.type):\($0.id)" } ?? [])")
    }

    /// Two seasons of one series reach the row when it spans several libraries; the row shows the
    /// series once, in the position its newest entry claimed.
    @Test("two entries of one series collapse to one card")
    func repeatedSeriesCollapses() async throws {
        let service = RecordingService()
        service.libraries = [Self.showLibrary]
        service.showsLatest = [
            try Self.item(#"{"Id":"season-4","Name":"Staffel 4","Type":"Season","SeriesId":"series-discounter"}"#),
            try Self.item(#"{"Id":"season-3","Name":"Staffel 3","Type":"Season","SeriesId":"series-discounter"}"#),
        ]
        service.itemsByID = [
            "series-discounter": try Self.item(#"{"Id":"series-discounter","Name":"Die Discounter","Type":"Series"}"#),
        ]
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let row = vm.rows.first { $0.type == .latestShows }
        #expect(row?.items.map(\.id) == ["series-discounter"])
    }
}

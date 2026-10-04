import Foundation
import Testing
@testable import Sodalite

@MainActor
struct ServerScopedStoresTests {
    /// Answers every batch with the same video range, so two fakes tell their servers apart.
    @MainActor
    private final class RangeLibrary: JellyfinLibraryServiceProtocol {
        let range: String
        private(set) var userIDs: [String] = []
        init(range: String) { self.range = range }

        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            userIDs.append(userID)
            let items = (query.ids ?? []).map {
                #"{"Id":"\#($0)","Name":"\#($0)","Type":"Movie","MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"VideoRangeType":"\#(range)"}]}"#
            }
            return try JSONDecoder().decode(
                JellyfinItemsResponse.self,
                from: Data(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(items.count)}"#.utf8))
        }
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { .init(items: [], totalRecordCount: 0) }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func movie(_ id: String, server: String) throws -> JellyfinItem {
        try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","ServerId":"\#(server)"}"#.utf8))
    }

    @Test func badgesFromTwoServersDoNotCollide() async throws {
        let a = RangeLibrary(range: "SDR")
        let b = RangeLibrary(range: "HDR10")
        let store = PosterBadgeStore(
            route: { serverID in serverID == "b" ? (b, "user-b") : (a, "user-a") },
            isEnabled: { true })
        let fromA = try movie("same-id", server: "a")
        let fromB = try movie("same-id", server: "b")

        await store.enrich(userID: "user-a", [fromA, fromB])

        #expect(store.badges(for: fromA) != store.badges(for: fromB))
        #expect(a.userIDs == ["user-a"])
        #expect(b.userIDs == ["user-b"])
    }

    @Test func hdr10ProbeKeysAndAsksByServer() async throws {
        var asked: [String?] = []
        let store = HDR10PlusProbeStore(
            streamURL: { item, sourceID, _ in
                asked.append(item.serverID)
                return URL(string: "https://\(item.serverID ?? "x").example/Videos/\(item.id)/stream?MediaSourceId=\(sourceID)")
            },
            isEnabled: { true },
            probe: { _, _ in true })
        func hdr(_ server: String) throws -> JellyfinItem {
            let stream = #"{"Index":0,"Type":"Video","Width":3840,"Height":2160,"VideoRangeType":"HDR10"}"#
            return try JSONDecoder().decode(JellyfinItem.self, from: Data(
                #"{"Id":"m1","Name":"m1","Type":"Movie","ServerId":"\#(server)","Width":3840,"Height":2160,"MediaStreams":[\#(stream)],"MediaSources":[{"Id":"src1","Container":"mkv","MediaStreams":[\#(stream)]}]}"#.utf8))
        }

        await store.probeIfNeeded(item: try hdr("a"), sourceID: "src1")
        await store.probeIfNeeded(item: try hdr("b"), sourceID: "src1")

        #expect(asked == ["a", "b"])
        #expect(store.carriesHDR10Plus(item: try hdr("b"), sourceID: "src1"))
    }
}

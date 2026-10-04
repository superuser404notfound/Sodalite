import Foundation
import Testing
@testable import Sodalite

@MainActor
struct MergedPagerTests {
    private func item(_ id: String, server: String, sort: String, rating: Double? = nil, tmdb: String? = nil) throws -> JellyfinItem {
        var extra = ""
        if let rating { extra += #","CommunityRating":\#(rating)"# }
        if let tmdb { extra += #","ProviderIds":{"Tmdb":"\#(tmdb)"}"# }
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"\#(sort)","SortName":"\#(sort)","Type":"Movie","ServerId":"\#(server)"\#(extra)}"#.utf8))
    }

    /// A fake server that serves `all` in pages, as Jellyfin would for StartIndex/Limit.
    private func source(_ server: String, _ all: [JellyfinItem], active: Bool = false, failAfter: Int? = nil) -> MergedPager.Source {
        let calls = Counter()
        return MergedPager.Source(serverID: server, isActive: active) { start, limit in
            let n = calls.next()
            if let failAfter, n >= failAfter { throw URLError(.networkConnectionLost) }
            let page = Array(all.dropFirst(start).prefix(limit))
            return JellyfinItemsResponse(items: page, totalRecordCount: all.count)
        }
    }

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    private func drain(_ pager: MergedPager) async -> [JellyfinItem] {
        var all: [JellyfinItem] = []
        repeat { all += await pager.nextPage() } while pager.hasMore
        return all
    }

    @Test func unevenSourcesPageWithoutGapsOrRepeats() async throws {
        let a = try (0..<120).map { try item("a\($0)", server: "a", sort: String(format: "a%03d", $0 * 2)) }
        let b = try (0..<7).map { try item("b\($0)", server: "b", sort: String(format: "a%03d", $0 * 2 + 1)) }
        let pager = MergedPager(sources: [source("a", a, active: true), source("b", b)], sort: .default, pageSize: 50)
        let all = await drain(pager)
        #expect(all.count == 127)
        #expect(Set(all.map(\.originKey)).count == 127)
        #expect(all.map { $0.sortName ?? "" } == all.map { $0.sortName ?? "" }.sorted())
        #expect(!pager.hasMore)
    }

    @Test func firstPageIsPageSizeLong() async throws {
        let a = try (0..<80).map { try item("a\($0)", server: "a", sort: String(format: "a%03d", $0)) }
        let b = try (0..<80).map { try item("b\($0)", server: "b", sort: String(format: "b%03d", $0)) }
        let pager = MergedPager(sources: [source("a", a, active: true), source("b", b)], sort: .default, pageSize: 50)
        #expect(await pager.nextPage().count == 50)
        #expect(pager.hasMore)
    }

    @Test func duplicatesAcrossPageBoundariesAppearOnce() async throws {
        let a = try (0..<60).map { try item("a\($0)", server: "a", sort: String(format: "m%03d", $0), tmdb: "\($0)") }
        let b = try (0..<60).map { try item("b\($0)", server: "b", sort: String(format: "m%03d", $0), tmdb: "\($0)") }
        let pager = MergedPager(sources: [source("a", a, active: true), source("b", b)], sort: .default, pageSize: 25)
        let all = await drain(pager)
        #expect(all.count == 60)
        #expect(all.allSatisfy { $0.serverID == "a" })
    }

    @Test func failingSourceDropsOutMidScroll() async throws {
        let a = try (0..<90).map { try item("a\($0)", server: "a", sort: String(format: "a%03d", $0 * 2)) }
        let b = try (0..<90).map { try item("b\($0)", server: "b", sort: String(format: "a%03d", $0 * 2 + 1)) }
        let pager = MergedPager(sources: [source("a", a, active: true), source("b", b, failAfter: 1)], sort: .default, pageSize: 30)
        let all = await drain(pager)
        #expect(all.filter { $0.serverID == "a" }.count == 90)
        #expect(pager.failedServerIDs == ["b"])
    }

    @Test func missingKeysSortLastBothWays() throws {
        let rated = try item("r", server: "a", sort: "b", rating: 7)
        let unrated = try item("u", server: "a", sort: "a")
        let desc = LibrarySort(key: .rating, descending: true)
        let asc = LibrarySort(key: .rating, descending: false)
        #expect(desc.orders(rated, before: unrated) == true)
        #expect(asc.orders(rated, before: unrated) == true)
        let tieA = try item("t1", server: "a", sort: "alpha", rating: 5)
        let tieB = try item("t2", server: "b", sort: "beta", rating: 5)
        // One SortOrder for every field, as the server applies it: the tiebreaker runs Z-A too.
        #expect(desc.orders(tieA, before: tieB) == false)
        #expect(asc.orders(tieA, before: tieB) == true)
    }

    @Test func oneSourcePagesLikeTheServer() async throws {
        let a = try (0..<70).map { try item("a\($0)", server: "a", sort: String(format: "a%03d", $0)) }
        let pager = MergedPager(sources: [source("a", a, active: true)], sort: .default, pageSize: 50)
        #expect(await pager.nextPage().map(\.id) == Array(a.prefix(50)).map(\.id))
        #expect(await pager.nextPage().map(\.id) == Array(a.dropFirst(50)).map(\.id))
        #expect(!pager.hasMore)
    }
}

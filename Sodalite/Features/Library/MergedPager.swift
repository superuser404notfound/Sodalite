import Foundation

/// A grid page drawn from several servers at once: one cursor per server, a k-way merge in the
/// grid's sort order, the same title from two servers shown once (Sodalite#85). A server that
/// fails or misses its deadline drops out and the rest keep paging.
@MainActor
final class MergedPager {
    typealias Fetch = @MainActor @Sendable (_ startIndex: Int, _ limit: Int) async throws -> JellyfinItemsResponse

    struct Source {
        let serverID: String
        let isActive: Bool
        let fetch: Fetch
    }

    private struct Cursor {
        let source: Source
        var buffer: [JellyfinItem] = []
        var nextStart = 0
        var exhausted = false
    }

    private var cursors: [Cursor]
    private let sort: LibrarySort
    private let pageSize: Int
    private let deadline: Duration
    private var emittedKeys = Set<String>()
    private(set) var failedServerIDs: [String] = []

    init(sources: [Source], sort: LibrarySort, pageSize: Int, deadline: Duration = .seconds(4)) {
        self.cursors = sources.map { Cursor(source: $0) }
        self.sort = sort
        self.pageSize = pageSize
        self.deadline = deadline
    }

    var hasMore: Bool { cursors.contains { !$0.exhausted || !$0.buffer.isEmpty } }

    func nextPage() async -> [JellyfinItem] {
        var page: [JellyfinItem] = []
        while page.count < pageSize {
            await refill()
            guard let index = headIndex() else { break }
            let item = cursors[index].buffer.removeFirst()
            if let key = HomeMerger.dedupeKey(item), !emittedKeys.insert(key).inserted { continue }
            page.append(item)
        }
        return page
    }

    /// Every cursor that ran dry and is not exhausted fetches its next page, all at once, so the
    /// head comparison always sees one item from every server still in play.
    private func refill() async {
        let needy = cursors.indices.filter { cursors[$0].buffer.isEmpty && !cursors[$0].exhausted }
        guard !needy.isEmpty else { return }
        let limit = pageSize
        let deadline = deadline
        let results = await withTaskGroup(of: (Int, JellyfinItemsResponse?).self) { group in
            for index in needy {
                let source = cursors[index].source
                let start = cursors[index].nextStart
                group.addTask {
                    let run: @MainActor @Sendable () async -> JellyfinItemsResponse? = { try? await source.fetch(start, limit) }
                    return (index, source.isActive ? await run() : await Deadline.race(deadline) { await run() } ?? nil)
                }
            }
            var collected: [Int: JellyfinItemsResponse?] = [:]
            for await (index, response) in group { collected[index] = response }
            return collected
        }
        for index in needy {
            guard let response = results[index] ?? nil else {
                cursors[index].exhausted = true
                if !failedServerIDs.contains(cursors[index].source.serverID) {
                    failedServerIDs.append(cursors[index].source.serverID)
                }
                continue
            }
            let serverID = cursors[index].source.serverID
            cursors[index].buffer = response.items.map { item in
                var stamped = item
                if stamped.serverID == nil { stamped.serverID = serverID }
                return stamped
            }
            cursors[index].nextStart += response.items.count
            if response.items.count < limit || cursors[index].nextStart >= response.totalRecordCount {
                cursors[index].exhausted = true
            }
        }
    }

    private func headIndex() -> Int? {
        var best: Int?
        for index in cursors.indices where !cursors[index].buffer.isEmpty {
            guard let current = best else { best = index; continue }
            let candidate = cursors[index].buffer[0]
            let leader = cursors[current].buffer[0]
            if sort.orders(candidate, before: leader) == true { best = index }
        }
        return best
    }
}

extension MergedPager {
    /// One pager source per Home source, each running the grid's query with its own user.
    static func sources(from homeSources: [HomeSource], query: ItemQuery) -> [Source] {
        homeSources.map { source in
            Source(serverID: source.serverID, isActive: source.isActive) { start, limit in
                var page = query
                page.startIndex = start
                page.limit = limit
                return try await source.libraryService.getItems(userID: source.userID, query: page)
            }
        }
    }
}

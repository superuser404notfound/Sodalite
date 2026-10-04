import Foundation

/// The smart-provider grid of a combined Home: every server's studio match and TMDB map, joined
/// (Sodalite#85). Complete by construction, like the single-server grid.
enum CombinedProviderMatch {
    nonisolated static func unionTmdbMaps(_ maps: [[String: JellyfinItem]]) -> [String: JellyfinItem] {
        var union: [String: JellyfinItem] = [:]
        for map in maps {
            union.merge(map) { first, _ in first }
        }
        return union
    }

    nonisolated static func mergeStudioMatches(_ lists: [[JellyfinItem]]) -> [JellyfinItem] {
        HomeMerger.merge(lists, type: .allMovies, mergedContinueWatching: false, limit: .max)
    }

    /// Both phases' inputs from every source at once, secondaries capped by `deadline`. `phase1` is
    /// nil when the active server's studio match failed and `allItems` nil when its library scan
    /// failed, the same "failed, not empty" signals the single-server grid reads.
    static func fetch(
        sources: [HomeSource],
        studioQuery: ItemQuery,
        libraryQuery: ItemQuery?,
        deadline: Duration
    ) async -> (phase1: JellyfinItemsResponse?, allItems: [JellyfinItem]?, tmdbMap: [String: JellyfinItem]) {
        typealias Answer = (studio: [JellyfinItem]?, library: [JellyfinItem]?)
        var answers: [Int: Answer?] = [:]
        await withTaskGroup(of: (Int, Answer?).self) { group in
            for (index, source) in sources.enumerated() {
                let run: @MainActor @Sendable () async -> Answer = {
                    async let studio = try? source.libraryService.getItems(userID: source.userID, query: studioQuery).items
                    let library: [JellyfinItem]?
                    if let libraryQuery {
                        library = try? await source.libraryService.getItems(userID: source.userID, query: libraryQuery).items
                    } else {
                        library = []
                    }
                    return (await studio, library)
                }
                let isActive = source.isActive
                group.addTask {
                    (index, isActive ? await run() : await Deadline.race(deadline) { await run() })
                }
            }
            for await (index, answer) in group { answers[index] = answer }
        }
        var studioLists: [[JellyfinItem]] = []
        var maps: [[String: JellyfinItem]] = []
        var allItems: [JellyfinItem] = []
        var phase1Failed = false
        var libraryFailed = false
        for (index, source) in sources.enumerated() {
            guard let answer = answers[index] ?? nil else { continue }
            let stamp = { (item: JellyfinItem) -> JellyfinItem in
                var stamped = item
                if stamped.serverID == nil { stamped.serverID = source.serverID }
                return stamped
            }
            if let studio = answer.studio { studioLists.append(studio.map(stamp)) } else if source.isActive { phase1Failed = true }
            if let library = answer.library {
                let stamped = library.map(stamp)
                allItems += stamped
                var map: [String: JellyfinItem] = [:]
                for item in stamped {
                    if let id = item.tmdbID { map[ProviderMatchMerging.tmdbKey(type: item.type, tmdbID: id)] = item }
                }
                maps.append(map)
            } else if source.isActive {
                libraryFailed = true
            }
        }
        let merged = mergeStudioMatches(studioLists)
        return (
            phase1Failed ? nil : JellyfinItemsResponse(items: merged, totalRecordCount: merged.count),
            libraryFailed ? nil : allItems,
            unionTmdbMaps(maps)
        )
    }
}

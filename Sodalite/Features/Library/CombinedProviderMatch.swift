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

    /// Both phases' inputs from every source at once. A secondary's studio match gets
    /// `studioDeadline`, its library scan the longer `scanDeadline`, raced separately so a slow scan
    /// does not cost the studio match too. `phase1` is nil when the active server's studio match
    /// failed and `allItems` nil when its scan failed, the same "failed, not empty" signals the
    /// single-server grid reads. `complete` is false when any secondary dropped out, and an
    /// incomplete result must not be cached.
    static func fetch(
        sources: [HomeSource],
        studioQuery: ItemQuery,
        libraryQuery: ItemQuery?,
        studioDeadline: Duration,
        scanDeadline: Duration
    ) async -> (phase1: JellyfinItemsResponse?, allItems: [JellyfinItem]?, tmdbMap: [String: JellyfinItem], complete: Bool) {
        typealias Answer = (studio: [JellyfinItem]?, library: [JellyfinItem]?)
        var answers: [Int: Answer] = [:]
        await withTaskGroup(of: (Int, Answer).self) { group in
            for (index, source) in sources.enumerated() {
                let studio: @MainActor @Sendable () async -> [JellyfinItem]? = {
                    try? await source.libraryService.getItems(userID: source.userID, query: studioQuery).items
                }
                let library: @MainActor @Sendable () async -> [JellyfinItem]? = {
                    guard let libraryQuery else { return [] }
                    return try? await source.libraryService.getItems(userID: source.userID, query: libraryQuery).items
                }
                let isActive = source.isActive
                group.addTask {
                    async let studioAnswer = isActive ? await studio() : await Deadline.race(studioDeadline) { await studio() } ?? nil
                    async let libraryAnswer = isActive ? await library() : await Deadline.race(scanDeadline) { await library() } ?? nil
                    return (index, (await studioAnswer, await libraryAnswer))
                }
            }
            for await (index, answer) in group { answers[index] = answer }
        }
        var studioLists: [[JellyfinItem]] = []
        var maps: [[String: JellyfinItem]] = []
        var allItems: [JellyfinItem] = []
        var phase1Failed = false
        var libraryFailed = false
        var complete = true
        for (index, source) in sources.enumerated() {
            let answer = answers[index] ?? (nil, nil)
            let stamp = { (item: JellyfinItem) -> JellyfinItem in
                var stamped = item
                if stamped.serverID == nil { stamped.serverID = source.serverID }
                return stamped
            }
            if let studio = answer.studio {
                studioLists.append(studio.map(stamp))
            } else if source.isActive {
                phase1Failed = true
            } else {
                complete = false
            }
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
            } else {
                complete = false
            }
        }
        let merged = mergeStudioMatches(studioLists)
        return (
            phase1Failed ? nil : JellyfinItemsResponse(items: merged, totalRecordCount: merged.count),
            libraryFailed ? nil : allItems,
            unionTmdbMaps(maps),
            complete
        )
    }
}

extension CombinedProviderMatch {
    /// `ProviderMatchMerging.merge`, plus the cross-server dedupe it cannot do: its id check misses
    /// the same title on two servers, which arrives once from the studio match and once from the
    /// TMDB map.
    nonisolated static func mergePhases(phase1: [JellyfinItem], phase2: [JellyfinItem]) -> [JellyfinItem] {
        var seen = Set<String>()
        return ProviderMatchMerging.merge(phase1: phase1, phase2: phase2).filter { item in
            guard let key = HomeMerger.dedupeKey(item) else { return true }
            return seen.insert(key).inserted
        }
    }
}

import Foundation

nonisolated private let log = ShelfLog(category: "Feed")

/// The shelf's two rows, fetched from every server the shelf's sessions name and merged the way
/// Home merges them (Sodalite#218). Both the extension and the app's artwork pass load through
/// here: they have to arrive at the same cells, or the files one renders are not the ones the
/// other looks for.
nonisolated struct TopShelfFeed: Sendable {
    let resume: [TopShelfItem]
    let nextUp: [TopShelfItem]
    let resumeFetched: Bool
    let nextUpFetched: Bool
    /// Some server's row came from the cache instead of the network.
    let usedCache: Bool
    /// Every row of every server either answered or had a cache to stand in. A pass built from less
    /// would sweep the missing server's artwork.
    let complete: Bool
    /// The secondaries whose rows this holds, fetched or from a cache that covered them: what a
    /// cache written from this feed may claim to cover.
    let coveredSecondaries: [String]

    static let rowLimit = 10

    /// `cache` is only called when a fetch failed: a healthy load never touches the container.
    static func load(sessions: ShelfSessions,
                     hidden: TopShelfHiddenShows?,
                     cache: () -> TopShelfCache?) async -> TopShelfFeed {
        let all = sessions.all
        let fetched = await withTaskGroup(of: (Int, [TopShelfItem]?, [TopShelfItem]?).self,
                                          returning: [Int: ([TopShelfItem]?, [TopShelfItem]?)].self) { group in
            for (index, session) in all.enumerated() {
                group.addTask {
                    let api = TopShelfAPI(session: session)
                    async let resume = fetch("resume", session) { try await api.resumeItems(limit: rowLimit) }
                    async let nextUp = fetch("nextUp", session) { try await api.nextUp(limit: rowLimit) }
                    let stamp = { (items: [TopShelfItem]?) in items?.map { $0.stamped(serverID: session.serverID) } }
                    return (index, stamp(await resume), stamp(await nextUp))
                }
            }
            var collected: [Int: ([TopShelfItem]?, [TopShelfItem]?)] = [:]
            for await (index, resume, nextUp) in group { collected[index] = (resume, nextUp) }
            return collected
        }

        let anyFailure = all.indices.contains { fetched[$0]?.0 == nil || fetched[$0]?.1 == nil }
        let cached = anyFailure ? cache() : nil

        var resumeLists: [[TopShelfItem]] = []
        var nextUpLists: [[TopShelfItem]] = []
        var resumeFetched = false
        var nextUpFetched = false
        var complete = true
        var coveredSecondaries: [String] = []
        for (index, session) in all.enumerated() {
            let fromSource = { (items: [TopShelfItem]) in items.filter { $0.sourceServerID == session.serverID } }
            let hiddenHere = hidden?.hidden(for: sessions.active.userID, serverID: session.serverID) ?? []
            let resume = fetched[index]?.0
            let nextUp = fetched[index]?.1
            resumeFetched = resumeFetched || resume != nil
            nextUpFetched = nextUpFetched || nextUp != nil
            let covered = (resume != nil && nextUp != nil) || cached?.covers(serverID: session.serverID) == true
            complete = complete && covered
            if covered, let serverID = session.serverID { coveredSecondaries.append(serverID) }
            resumeLists.append(TopShelfItem.removingHidden(resume ?? cached.map { fromSource($0.resume) } ?? [],
                                                           hidden: hiddenHere))
            nextUpLists.append(TopShelfItem.removingHidden(nextUp ?? cached.map { fromSource($0.nextUp) } ?? [],
                                                           hidden: hiddenHere))
        }

        let resume = TopShelfMerger.resume(resumeLists, limit: rowLimit)
        // A title can be in progress on one server and next up on another; it belongs in Continue
        // Watching only, as it would in Home's combined row.
        let resumeTitles = Set(resume.compactMap(TopShelfMerger.dedupeKey))
        let nextUp = TopShelfMerger.nextUp(nextUpLists, limit: rowLimit)
            .filter { TopShelfMerger.dedupeKey($0).map { !resumeTitles.contains($0) } ?? true }
        let rows = TopShelfItem.shelfRows(resume: resume, nextUp: nextUp)

        return TopShelfFeed(resume: rows.resume,
                            nextUp: rows.nextUp,
                            resumeFetched: resumeFetched,
                            nextUpFetched: nextUpFetched,
                            usedCache: cached != nil,
                            complete: complete,
                            coveredSecondaries: coveredSecondaries)
    }

    /// nil is a failed fetch, [] is a genuinely empty row; the cache fallback needs to tell them apart.
    private static func fetch(_ label: String,
                              _ session: SharedSession,
                              _ work: () async throws -> [TopShelfItem]) async -> [TopShelfItem]? {
        do {
            return try await work()
        } catch {
            let server = session.serverID.map { " server=\($0.prefix(8))" } ?? ""
            log.error("\(label) fetch failed\(server): \(error.localizedDescription)")
            return nil
        }
    }
}

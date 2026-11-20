import Foundation

/// The merged half of a combined Home's genre or studio grid, out of the view so it can be held to
/// account (Sodalite#85). It keeps paged results across a return from a detail page, drops a page
/// that belongs to a pager it has since replaced, and never replaces what is on screen with the
/// answer of a load whose active server failed.
@MainActor
final class MergedGridState {
    enum Outcome: Equatable {
        /// New first page; `cacheable` only when every server answered.
        case replaced(cacheable: Bool)
        /// Pages already loaded stay (a reappear with the same filter and sort).
        case kept
        /// The active server did not answer; what is on screen stays.
        case failed
    }

    private(set) var items: [JellyfinItem] = []
    private var pager: MergedPager?
    private var paginated = false
    private var generation = 0

    var hasMore: Bool { pager?.hasMore ?? false }

    /// The filter or sort changed: the next load starts over and any page still in flight is dropped.
    func reset() {
        generation &+= 1
        pager = nil
        paginated = false
        items = []
    }

    func load(
        sources: [MergedPager.Source],
        sort: LibrarySort,
        pageSize: Int,
        filter: ([JellyfinItem]) -> [JellyfinItem] = { $0 }
    ) async -> Outcome {
        if pager != nil, paginated { return .kept }
        generation &+= 1
        let current = generation
        let fresh = MergedPager(sources: sources, sort: sort, pageSize: pageSize)
        let first = filter(await fresh.nextPage())
        guard current == generation else { return .kept }
        if let active = sources.first(where: \.isActive)?.serverID, fresh.failedServerIDs.contains(active) {
            return .failed
        }
        pager = fresh
        paginated = false
        items = first
        return .replaced(cacheable: fresh.failedServerIDs.isEmpty)
    }

    /// Appends the next page; false when there was none or it belonged to a replaced pager.
    func loadMore(filter: ([JellyfinItem]) -> [JellyfinItem] = { $0 }) async -> Bool {
        guard let current = pager else { return false }
        let started = generation
        let page = filter(await current.nextPage())
        guard started == generation, current === pager else { return false }
        let known = Set(items.map(\.originKey))
        items += page.filter { !known.contains($0.originKey) }
        paginated = true
        return true
    }
}

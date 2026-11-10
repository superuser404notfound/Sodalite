import Foundation
import Observation

/// One grid cell: not fetched yet, a title, or a title the grid drops client-side (Sodalite#73).
enum SparseGridSlot: Equatable {
    case pending
    case loaded(JellyfinItem)
    case hidden

    static func == (lhs: SparseGridSlot, rhs: SparseGridSlot) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.hidden, .hidden): true
        case let (.loaded(l), .loaded(r)): l.originKey == r.originKey
        default: false
        }
    }
}

/// A library grid with one slot per server record, filled one fixed page at a time (Sodalite#86).
/// Every slot has an absolute position, so a jump fetches the destination page and not the gap,
/// which is what makes the alphabet rail usable on a slow server.
@Observable @MainActor
final class SparseGridStore {
    typealias Fetch = @MainActor @Sendable (_ startIndex: Int, _ limit: Int) async throws -> JellyfinItemsResponse

    enum FirstPageState: Equatable {
        case loading
        case loaded([JellyfinItem])
        case failed

        static func == (lhs: FirstPageState, rhs: FirstPageState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.failed, .failed): true
            case let (.loaded(l), .loaded(r)): l.map(\.originKey) == r.map(\.originKey)
            default: false
            }
        }
    }

    let pageSize: Int
    private let maxInFlight: Int

    private(set) var slots: [SparseGridSlot] = []
    private(set) var visibleIndices: [Int] = []
    private(set) var firstPage: FirstPageState = .loading
    /// True once a response has sized the grid; a cached seed is only the first page, so a letter
    /// past it cannot be reached until then.
    private(set) var knowsTotal = false

    @ObservationIgnored private var fetch: Fetch?
    @ObservationIgnored private var isHidden: (JellyfinItem) -> Bool = { _ in false }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedPages: Set<Int> = []
    @ObservationIgnored private var inFlight: [Int: Task<Void, Never>] = [:]
    /// Most recent last; popped from the end.
    @ObservationIgnored private var queue: [Int] = []
    @ObservationIgnored private var visibleSlotsPerPage: [Int: Int] = [:]

    /// `seed` paints the cached first page before the session exists to fetch with.
    init(pageSize: Int, maxInFlight: Int = 2, seed: [JellyfinItem] = []) {
        self.pageSize = max(1, pageSize)
        self.maxInFlight = max(1, maxInFlight)
        slots = seed.map { .loaded($0) }
        rebuildVisibleIndices()
    }

    var loadedItems: [JellyfinItem] {
        slots.compactMap { if case .loaded(let item) = $0 { item } else { nil } }
    }

    func item(at index: Int) -> JellyfinItem? {
        guard slots.indices.contains(index), case .loaded(let item) = slots[index] else { return nil }
        return item
    }

    func visibleIndex(atOrAfter index: Int) -> Int? {
        visibleIndices.first { $0 >= index } ?? visibleIndices.last
    }

    func start(fetch: @escaping Fetch, isHidden: @escaping (JellyfinItem) -> Bool, seed: [JellyfinItem]) {
        reset()
        self.fetch = fetch
        self.isHidden = isHidden
        slots = seed.map { isHidden($0) ? .hidden : .loaded($0) }
        rebuildVisibleIndices()
        enqueue(page: 0)
    }

    func reset() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        queue = []
        loadedPages = []
        visibleSlotsPerPage = [:]
        slots = []
        visibleIndices = []
        firstPage = .loading
        knowsTotal = false
        fetch = nil
    }

    func slotAppeared(_ index: Int) {
        let page = index / pageSize
        visibleSlotsPerPage[page, default: 0] += 1
        enqueue(page: page)
    }

    func slotDisappeared(_ index: Int) {
        let page = index / pageSize
        let remaining = (visibleSlotsPerPage[page] ?? 1) - 1
        visibleSlotsPerPage[page] = remaining > 0 ? remaining : nil
        if remaining <= 0 { queue.removeAll { $0 == page } }
    }

    /// A reappear (back from a detail screen): every page goes stale but stays on screen, and the
    /// first page plus the visible ones refetch, so a title just watched picks up its new state.
    func revalidate() {
        guard fetch != nil else { return }
        loadedPages = []
        enqueue(page: 0)
        for page in visibleSlotsPerPage.keys.sorted() { enqueue(page: page) }
    }

    func prioritize(slot: Int) {
        enqueue(page: slot / pageSize)
    }

    func waitForIdle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private func enqueue(page: Int) {
        guard !loadedPages.contains(page), inFlight[page] == nil else { return }
        queue.removeAll { $0 == page }
        queue.append(page)
        pump()
    }

    private func pump() {
        while inFlight.count < maxInFlight, let page = queue.popLast() {
            load(page: page)
        }
    }

    private func load(page: Int) {
        guard let fetch else { return }
        let generation = generation
        let start = page * pageSize
        inFlight[page] = Task { [pageSize] in
            // A server may answer a page short and still report more behind it: AIOMetadata caps a
            // request over 100 at 50 and reports only one page of lookahead as its total. The rest
            // of the page is asked for until it is full or the list ends.
            var filled = 0
            var failed = false
            while filled < pageSize {
                let response = try? await fetch(start + filled, pageSize - filled)
                guard !Task.isCancelled, generation == self.generation else { return }
                guard let response else { failed = true; break }
                self.apply(response, at: start + filled, requested: pageSize - filled, page: page, isFirstChunk: filled == 0)
                filled += response.items.count
                if response.items.isEmpty || start + filled >= response.totalRecordCount { break }
            }
            self.inFlight[page] = nil
            if failed {
                if filled > 0 { self.loadedPages.remove(page) }
                if page == 0, self.loadedPages.isEmpty, filled == 0 { self.firstPage = .failed }
            }
            self.pump()
        }
    }

    private func apply(_ response: JellyfinItemsResponse, at start: Int, requested: Int, page: Int, isFirstChunk: Bool) {
        let end = start + response.items.count
        // A full answer whose total stops exactly at its last item may be a server that reports only
        // what it served (AIOMetadata does this for a cross-library list). One pending slot past it
        // asks for the next page once it scrolls into view; an empty answer there ends the grid.
        let endsAtFullAnswer = end >= response.totalRecordCount && response.items.count >= requested
        let total = endsAtFullAnswer ? end + 1 : response.totalRecordCount
        if slots.count < total {
            slots += Array(repeating: .pending, count: total - slots.count)
        } else if slots.count > total, end >= total, !endsAtFullAnswer {
            // Only a response that provably reaches the end of the list may shorten the grid. Before
            // that its total can be a lower bound (AIOMetadata's lookahead), and a refetch of page 0
            // would cut every page already read behind it.
            slots.removeLast(slots.count - total)
            loadedPages = loadedPages.filter { $0 * pageSize < total }
        }
        for (offset, item) in response.items.enumerated() where start + offset < slots.count {
            slots[start + offset] = isHidden(item) ? .hidden : .loaded(item)
        }
        loadedPages.insert(page)
        knowsTotal = true
        if page == 0, isFirstChunk { firstPage = .loaded(response.items) }
        rebuildVisibleIndices()
    }

    private func rebuildVisibleIndices() {
        visibleIndices = slots.indices.filter { slots[$0] != .hidden }
    }
}

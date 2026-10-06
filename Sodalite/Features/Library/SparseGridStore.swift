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
            let response = try? await fetch(start, pageSize)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.inFlight[page] = nil
            if let response {
                self.apply(response, page: page)
            } else if page == 0, self.loadedPages.isEmpty {
                self.firstPage = .failed
            }
            self.pump()
        }
    }

    private func apply(_ response: JellyfinItemsResponse, page: Int) {
        let total = response.totalRecordCount
        if slots.count < total {
            slots += Array(repeating: .pending, count: total - slots.count)
        } else if slots.count > total {
            slots.removeLast(slots.count - total)
            loadedPages = loadedPages.filter { $0 * pageSize < total }
        }
        let start = page * pageSize
        for (offset, item) in response.items.enumerated() where start + offset < slots.count {
            slots[start + offset] = isHidden(item) ? .hidden : .loaded(item)
        }
        loadedPages.insert(page)
        if page == 0 { firstPage = .loaded(response.items) }
        rebuildVisibleIndices()
    }

    private func rebuildVisibleIndices() {
        visibleIndices = slots.indices.filter { slots[$0] != .hidden }
    }
}

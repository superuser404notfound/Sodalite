import Foundation
import Testing
@testable import Sodalite

@MainActor
struct SparseGridStoreTests {
    /// MainActor-isolated so the `@Sendable` fetch closure may capture it under Swift 6.
    @MainActor final class Server {
        var all: [JellyfinItem]
        var requests: [Int] = []
        var failing: Set<Int> = []
        var totalOverride: Int?
        init(count: Int) { all = (0..<count).map { Server.item("i\($0)") } }
        static func item(_ id: String, type: String = "Movie") -> JellyfinItem {
            try! JSONDecoder().decode(JellyfinItem.self,
                from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"}"#.utf8))
        }
        func fetch(_ start: Int, _ limit: Int) async throws -> JellyfinItemsResponse {
            requests.append(start)
            if failing.contains(start) { throw URLError(.timedOut) }
            return JellyfinItemsResponse(items: Array(all.dropFirst(start).prefix(limit)),
                                         totalRecordCount: totalOverride ?? all.count)
        }
    }

    private func started(_ server: Server, pageSize: Int = 10, seed: [JellyfinItem] = [],
                         hidden: @escaping (JellyfinItem) -> Bool = { _ in false }) async -> SparseGridStore {
        let store = SparseGridStore(pageSize: pageSize)
        store.start(fetch: { try await server.fetch($0, $1) }, isHidden: hidden, seed: seed)
        await store.waitForIdle()
        return store
    }

    @Test func firstPageSizesTheGridToTheTotal() async {
        let server = Server(count: 35)
        let store = await started(server)
        #expect(store.slots.count == 35)
        #expect(server.requests == [0])
        #expect(store.item(at: 9)?.id == "i9")
        #expect(store.slots[10] == .pending)
        if case .loaded(let items) = store.firstPage { #expect(items.count == 10) } else { Issue.record("first page") }
    }

    @Test func slotLoadsItsOwnPageAtAnAbsoluteOffset() async {
        let server = Server(count: 100)
        let store = await started(server)
        store.slotAppeared(57)
        await store.waitForIdle()
        #expect(server.requests == [0, 50])
        #expect(store.item(at: 57)?.id == "i57")
        #expect(store.slots[40] == .pending)
    }

    @Test func aPageIsRequestedOnce() async {
        let server = Server(count: 100)
        let store = await started(server)
        for i in 20..<30 { store.slotAppeared(i) }
        await store.waitForIdle()
        store.slotAppeared(25)
        await store.waitForIdle()
        #expect(server.requests == [0, 20])
    }

    @Test func offscreenPagesLeaveTheQueue() async {
        let server = Server(count: 200)
        let store = SparseGridStore(pageSize: 10, maxInFlight: 1)
        store.start(fetch: { try await server.fetch($0, $1) }, isHidden: { _ in false }, seed: [])
        // Page 0 is in flight; these three queue behind it.
        store.slotAppeared(30); store.slotAppeared(60); store.slotAppeared(90)
        store.slotDisappeared(30); store.slotDisappeared(60)
        await store.waitForIdle()
        #expect(server.requests == [0, 90])
    }

    @Test func newestRequestGoesFirst() async {
        let server = Server(count: 200)
        let store = SparseGridStore(pageSize: 10, maxInFlight: 1)
        store.start(fetch: { try await server.fetch($0, $1) }, isHidden: { _ in false }, seed: [])
        store.slotAppeared(30); store.slotAppeared(60)
        await store.waitForIdle()
        #expect(server.requests == [0, 60, 30])
    }

    @Test func prioritizedSlotLoadsWithoutAppearing() async {
        let server = Server(count: 200)
        let store = await started(server)
        store.prioritize(slot: 150)
        await store.waitForIdle()
        #expect(server.requests == [0, 150])
    }

    @Test func totalShrinkTruncatesSlotsAndForgetsPages() async {
        let server = Server(count: 100)
        let store = await started(server)
        store.slotAppeared(95)
        await store.waitForIdle()
        server.all = Array(server.all.prefix(60))
        store.slotAppeared(55)
        await store.waitForIdle()
        #expect(store.slots.count == 60)
        #expect(store.visibleIndices.last == 59)
    }

    @Test func totalGrowAppendsPending() async {
        let server = Server(count: 30)
        let store = await started(server)
        server.all += (30..<45).map { Server.item("n\($0)") }
        store.slotAppeared(15)
        await store.waitForIdle()
        #expect(store.slots.count == 45)
        #expect(store.slots[44] == .pending)
    }

    @Test func staleGenerationIsDiscarded() async {
        let old = Server(count: 50)
        let fresh = Server(count: 5)
        let store = SparseGridStore(pageSize: 10)
        store.start(fetch: { try await old.fetch($0, $1) }, isHidden: { _ in false }, seed: [])
        store.start(fetch: { try await fresh.fetch($0, $1) }, isHidden: { _ in false }, seed: [])
        await store.waitForIdle()
        #expect(store.slots.count == 5)
    }

    @Test func failedPageRetriesOnReappear() async {
        let server = Server(count: 100)
        let store = await started(server)
        server.failing = [20]
        store.slotAppeared(25)
        await store.waitForIdle()
        #expect(store.slots[25] == .pending)
        server.failing = []
        store.slotDisappeared(25)
        store.slotAppeared(25)
        await store.waitForIdle()
        #expect(store.item(at: 25)?.id == "i25")
    }

    @Test func failedFirstPageIsReported() async {
        let server = Server(count: 100)
        server.failing = [0]
        let store = await started(server)
        #expect(store.firstPage == .failed)
        #expect(store.slots.isEmpty)
    }

    @Test func seedPaintsBeforeTheFetchAndIsReplaced() async {
        let server = Server(count: 30)
        let store = SparseGridStore(pageSize: 10)
        store.start(fetch: { try await server.fetch($0, $1) }, isHidden: { _ in false },
                    seed: [Server.item("cached")])
        #expect(store.item(at: 0)?.id == "cached")
        await store.waitForIdle()
        #expect(store.item(at: 0)?.id == "i0")
        #expect(store.slots.count == 30)
    }

    @Test func hiddenItemsLeaveVisibleIndices() async {
        let server = Server(count: 10)
        server.all[3] = Server.item("audio", type: "Playlist")
        let store = await started(server, hidden: { $0.id == "audio" })
        #expect(store.slots[3] == .hidden)
        #expect(!store.visibleIndices.contains(3))
        #expect(store.visibleIndices.count == 9)
    }

    @Test func visibleIndexAtOrAfterSkipsHidden() async {
        let server = Server(count: 10)
        server.all[3] = Server.item("audio", type: "Playlist")
        let store = await started(server, hidden: { $0.id == "audio" })
        #expect(store.visibleIndex(atOrAfter: 3) == 4)
    }

    @Test func visibleIndexAtOrAfterClampsPastEnd() async {
        let store = await started(Server(count: 10))
        #expect(store.visibleIndex(atOrAfter: 500) == 9)
    }

    @Test func seededInitPaintsWithoutFetching() {
        let store = SparseGridStore(pageSize: 10, seed: [Server.item("cached")])
        #expect(store.item(at: 0)?.id == "cached")
        #expect(store.slots.count == 1)
    }

    @Test func revalidateRefetchesVisiblePagesAndKeepsTheGrid() async {
        let server = Server(count: 100)
        let store = await started(server)
        store.slotAppeared(25)
        await store.waitForIdle()
        server.all[25] = Server.item("changed")
        store.revalidate()
        #expect(store.item(at: 25)?.id == "i25")
        #expect(store.slots.count == 100)
        await store.waitForIdle()
        #expect(store.item(at: 25)?.id == "changed")
        #expect(server.requests.suffix(2).sorted() == [0, 20])
    }
}

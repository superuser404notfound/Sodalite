import Testing
import Foundation
@testable import Sodalite

/// Sodalite#117. In merged mode the Continue Watching row fetches resume items AND Next Up, and it
/// used to await the first before issuing the second. Every other row in Home's fan-out issues one
/// call and they all run concurrently, so this row was alone in paying two serial round trips, and
/// it is the row at the top of the screen. The pair now rides together.
///
/// Ordering, not wall-clock: a loaded CI box can stretch any duration, but it cannot make a call
/// that was issued after another one's return appear before it.
@MainActor
struct HomeContinueWatchingConcurrencyTests {

    /// Items are handed in rather than built here: `JellyfinItem`'s stub init is MainActor-isolated
    /// under default isolation, and these methods are not.
    final class PairedService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []

        let resumeItems: [JellyfinItem]
        let nextUpItems: [JellyfinItem]
        /// Long enough that a serialized pair could not overlap by accident, short enough to keep
        /// the suite fast.
        let resumeDelay: Duration
        let resumeFails: Bool
        let nextUpFails: Bool

        init(
            resumeItems: [JellyfinItem],
            nextUpItems: [JellyfinItem],
            resumeDelay: Duration = .milliseconds(200),
            resumeFails: Bool = false,
            nextUpFails: Bool = false
        ) {
            self.resumeItems = resumeItems
            self.nextUpItems = nextUpItems
            self.resumeDelay = resumeDelay
            self.resumeFails = resumeFails
            self.nextUpFails = nextUpFails
        }

        struct Unused: Error {}

        var events: [String] { lock.withLock { log } }
        private func note(_ event: String) { lock.withLock { log.append(event) } }

        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            note("resume:start")
            try? await Task.sleep(for: resumeDelay)
            note("resume:end")
            if resumeFails { throw Unused() }
            return JellyfinItemsResponse(items: resumeItems, totalRecordCount: resumeItems.count)
        }

        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            note("nextUp:start")
            if nextUpFails { throw Unused() }
            return JellyfinItemsResponse(items: nextUpItems, totalRecordCount: nextUpItems.count)
        }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw Unused() }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    private func item(_ id: String) -> JellyfinItem {
        JellyfinItem(seriesStub: id, name: id)
    }

    /// The repeated "resumed" is deliberate: Next Up excludes resumables server-side, so a repeat is
    /// the belt-and-suspenders case the row's dedupe exists for.
    private func makeService(
        resumeFails: Bool = false,
        nextUpFails: Bool = false
    ) -> PairedService {
        PairedService(
            resumeItems: [item("resumed")],
            nextUpItems: [item("resumed"), item("next")],
            resumeFails: resumeFails,
            nextUpFails: nextUpFails
        )
    }

    /// A fresh server id per test: the merge switch and the reconciled row config are both stored
    /// per server, and these must not inherit or leave behind one another's.
    private func makeViewModel(service: PairedService, merged: Bool) -> (HomeViewModel, String) {
        let serverID = "cw-\(UUID().uuidString)"
        HomeRowConfig.setMergeContinueWatchingNextUp(merged, serverID: serverID)
        let vm = HomeViewModel(
            libraryService: service,
            imageService: JellyfinImageService(baseURLProvider: { nil }),
            userID: "u1",
            serverID: serverID
        )
        return (vm, serverID)
    }

    private func forget(serverID: String) {
        UserDefaults.standard.removeObject(forKey: "homeRowConfigs.\(serverID)")
        UserDefaults.standard.removeObject(forKey: "homeMergeCWNextUp.\(serverID)")
    }

    private var config: HomeRowConfig {
        HomeRowConfig(type: .continueWatching, isEnabled: true, sortOrder: 0)
    }

    @Test("the merged row issues Next Up while resume items are still outstanding")
    func bothFetchesRideTogether() async {
        let service = makeService()
        let (vm, serverID) = makeViewModel(service: service, merged: true)
        defer { forget(serverID: serverID) }

        _ = await vm.loadRow(config: config)

        let events = service.events
        guard let nextUpStart = events.firstIndex(of: "nextUp:start"),
              let resumeEnd = events.firstIndex(of: "resume:end") else {
            Issue.record("one of the two calls never happened: \(events)")
            return
        }
        #expect(nextUpStart < resumeEnd, "Next Up waited for the resume response: \(events)")
    }

    @Test("resume items still lead the row, with Next Up deduped behind them")
    func mergedOrderAndDedupeSurvive() async {
        let service = makeService()
        let (vm, serverID) = makeViewModel(service: service, merged: true)
        defer { forget(serverID: serverID) }

        let row = await vm.loadRow(config: config)

        #expect(row?.items.map(\.id) == ["resumed", "next"])
    }

    /// The `try?` on the Next Up side: a Next Up failure must not take the resume items down with
    /// it. Concurrency moved the call, not that guarantee.
    @Test("a failing Next Up leaves the resume items showing")
    func failingNextUpKeepsResumeItems() async {
        let service = makeService(nextUpFails: true)
        let (vm, serverID) = makeViewModel(service: service, merged: true)
        defer { forget(serverID: serverID) }

        let row = await vm.loadRow(config: config)

        #expect(row?.items.map(\.id) == ["resumed"])
    }

    /// The other direction is unchanged too: resume is the row, so its failure is the row's.
    @Test("a failing resume still takes the row down")
    func failingResumeDropsTheRow() async {
        let service = makeService(resumeFails: true)
        let (vm, serverID) = makeViewModel(service: service, merged: true)
        defer { forget(serverID: serverID) }

        let row = await vm.loadRow(config: config)

        #expect(row == nil)
    }

    /// Unmerged is the default, and it must stay a single request: Next Up has its own row there.
    @Test("the unmerged row fetches resume items only")
    func unmergedRowIssuesOneCall() async {
        let service = makeService()
        let (vm, serverID) = makeViewModel(service: service, merged: false)
        defer { forget(serverID: serverID) }

        let row = await vm.loadRow(config: config)

        #expect(row?.items.map(\.id) == ["resumed"])
        #expect(!service.events.contains("nextUp:start"), "unmerged mode fetched Next Up: \(service.events)")
    }
}

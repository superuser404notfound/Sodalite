import Testing
import Foundation
@testable import Sodalite

/// Sodalite#122. `getLibraries` used to be awaited in front of the row fan-out, and nothing in the
/// fan-out waits on it: its result only reconciles the row config, and the failure path already had
/// a documented fallback. On a server that does not answer, that put a full request timeout of dead
/// time in front of every launch before a single row was even planned, spent under a bare spinner.
/// The reported device log shows exactly that: launch at 17:02:09, the first three requests failing
/// together at 17:02:40, and Home's own fan-out only starting there.
@MainActor
struct HomeLibraryFanOutTests {

    /// Records the order calls arrive in, so "did the rows wait for the library list" is observable
    /// rather than inferred from a wall-clock measurement that a loaded CI box could flake on.
    final class OrderingService: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []

        /// Stands in for the unanswered request the reporter's launch made. Long enough that a
        /// serialized fan-out could not possibly beat it, short enough to keep the suite fast.
        var librariesDelay: Duration = .milliseconds(300)
        /// nil makes getLibraries fail after its delay, which is the reported case.
        var libraries: [JellyfinLibrary]?

        struct Unused: Error {}

        var events: [String] { lock.withLock { log } }
        private func note(_ event: String) { lock.withLock { log.append(event) } }

        func getLibraries(userID: String) async throws -> [JellyfinLibrary] {
            note("libraries:start")
            try? await Task.sleep(for: librariesDelay)
            note("libraries:end")
            guard let libraries else { throw Unused() }
            return libraries
        }

        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse {
            note("resume")
            throw Unused()
        }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] {
            note("latest")
            return []
        }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            note("items")
            throw Unused()
        }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse {
            note("nextUp")
            throw Unused()
        }
        func getGenres(userID: String) async throws -> [NamedItem] { note("genres"); return [] }
        func getStudios(userID: String) async throws -> [NamedItem] { note("studios"); return [] }
    }

    /// A fresh server id per test: loadContent persists a reconciled config, and these must not
    /// inherit or leave behind one another's stored rows.
    private func makeViewModel(service: OrderingService) -> (HomeViewModel, String) {
        let serverID = "fanout-\(UUID().uuidString)"
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
    }

    @Test("rows start fetching while the library list is still outstanding")
    func rowsDoNotWaitForLibraries() async {
        let service = OrderingService()
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        let events = service.events
        guard let librariesEnd = events.firstIndex(of: "libraries:end") else {
            Issue.record("getLibraries never completed")
            return
        }
        let rowCallsBeforeLibrariesLanded = events[..<librariesEnd].filter { $0 != "libraries:start" }
        #expect(!rowCallsBeforeLibrariesLanded.isEmpty,
                "every row fetch waited for the library list: \(events)")
    }

    /// The failure path keeps its old meaning: the stored config stands, and the rows it names are
    /// fetched anyway. Only the waiting is gone.
    @Test("a failing library list still leaves the stored rows fetched")
    func failedLibrariesStillFetchesRows() async {
        let service = OrderingService()
        service.libraries = nil
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        await vm.loadContent()

        #expect(service.events.contains("resume"))
        #expect(service.events.contains("libraries:end"))
    }

    /// The fold's one real risk. Planning before reconciliation means a row that reconciliation
    /// ENABLES was not in the plan: a per-library row retired for redundancy hands its state to the
    /// aggregated row, and a row type new in this app version arrives with its default. Deferring
    /// those to the next launch would be a quiet regression, so they are scheduled into the group
    /// that is already draining.
    @Test("a row reconciliation adds is fetched in the same load")
    func reconciliationAddsRowsToTheRunningFanOut() async {
        let service = OrderingService()
        service.libraries = []
        service.librariesDelay = .milliseconds(50)
        let (vm, serverID) = makeViewModel(service: service)
        defer { forget(serverID: serverID) }

        // A stored config from an app version that only knew one row type. Reconciliation backfills
        // every type added since, each with its own default, which switches Latest Movies on.
        vm.rowConfigs = [HomeRowConfig(type: .continueWatching, isEnabled: true, sortOrder: 0)]

        await vm.loadContent()

        #expect(vm.rowConfigs.contains { $0.type == .latestMovies && $0.isEnabled })
        #expect(service.events.contains("latest"),
                "the row reconciliation enabled was never fetched: \(service.events)")
    }
}

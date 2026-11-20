import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-11-17 CAT-206 and CAT-207: the admin approval queue.
@MainActor
struct CatalogAdminQueueTests {
    private struct Boom: Error {}

    private final class Discover: SeerrDiscoverServiceProtocol, @unchecked Sendable {
        func trending(page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func popularMovies(page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func popularTV(page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func upcomingMovies(page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func upcomingTV(page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func moviesByGenre(genreID: Int, page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func tvByGenre(genreID: Int, page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func moviesByStudio(studioID: Int, page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func tvByNetwork(networkID: Int, page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func moviesByWatchProvider(providerID: Int, region: String, page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func tvByWatchProvider(providerID: Int, region: String, page: Int) async throws -> SeerrDiscoverResult { throw Boom() }
        func movieGenres() async throws -> [SeerrGenreSlide] { throw Boom() }
        func tvGenres() async throws -> [SeerrGenreSlide] { throw Boom() }
    }

    private final class Media: SeerrMediaServiceProtocol, @unchecked Sendable {
        func movieDetail(tmdbID: Int) async throws -> SeerrMovieDetail { throw Boom() }
        func tvDetail(tmdbID: Int) async throws -> SeerrTVDetail { throw Boom() }
        func tvSeasonDetail(tmdbID: Int, seasonNumber: Int) async throws -> SeerrSeasonDetail { throw Boom() }
        func collection(collectionID: Int) async throws -> SeerrCollection { throw Boom() }
        func recommendations(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] { [] }
        func similar(mediaType: SeerrMediaType, tmdbID: Int) async throws -> [SeerrMedia] { [] }
        func ratings(mediaType: SeerrMediaType, tmdbID: Int) async throws -> SeerrRatings { throw Boom() }
        func personDetail(tmdbID: Int) async throws -> SeerrPersonDetail { throw Boom() }
        func personCredits(tmdbID: Int) async throws -> SeerrPersonCredits { throw Boom() }
        func removeMovieFromRadarr(tmdbID: Int) async throws -> Bool { true }
        func removeSeriesFromSonarr(tmdbID: Int) async throws -> Bool { true }
    }

    private final class Requests: SeerrRequestServiceProtocol, @unchecked Sendable {
        var queue: [SeerrRequestFilter: [SeerrRequest]] = [:]
        var failQueue = false
        /// A mutation parks here until `open` holds, so the test decides what happens meanwhile.
        var open = false
        var started: Set<String> = []
        private func park(_ name: String) async {
            started.insert(name)
            for _ in 0..<500 where !open { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func createRequest(mediaType: SeerrMediaType, tmdbID: Int, seasons: [Int]?, serverID: Int?, profileID: Int?, rootFolder: String?, languageProfileID: Int?, tags: [Int]?) async throws -> SeerrRequest { throw Boom() }
        func myRequests(userID: Int, take: Int, skip: Int, sort: SeerrRequestSort) async throws -> SeerrRequestsResult { throw Boom() }
        func allRequests(filter: SeerrRequestFilter, take: Int, skip: Int) async throws -> SeerrRequestsResult {
            if failQueue { throw Boom() }
            let rows = take == 0 ? [] : (queue[filter] ?? [])
            let info = SeerrPageInfo(pages: 1, pageSize: 50, results: queue[filter]?.count ?? 0, page: 1)
            return SeerrRequestsResult(pageInfo: info, results: rows)
        }
        func approveRequest(requestID: Int) async throws -> SeerrRequest {
            await park("approve")
            throw Boom()
        }
        func retryRequest(requestID: Int) async throws -> SeerrRequest { throw Boom() }
        func declineRequest(requestID: Int) async throws -> SeerrRequest { throw Boom() }
        func deleteRequest(requestID: Int) async throws {
            await park("delete")
            throw Boom()
        }
        func updateRequest(requestID: Int, body: SeerrRequestUpdateBody) async throws -> SeerrRequest { throw Boom() }
    }

    private func request(_ id: Int) -> SeerrRequest {
        let json = "{\"id\": \(id), \"status\": 1, \"type\": \"movie\"}"
        return try! JSONDecoder().decode(SeerrRequest.self, from: Data(json.utf8))
    }

    private func model(_ requests: Requests) -> CatalogViewModel {
        CatalogViewModel(discoverService: Discover(), requestService: requests, mediaService: Media())
    }

    @Test func aFailedQueueLoadIsAnErrorOfItsOwn() async {
        let requests = Requests()
        requests.failQueue = true
        let vm = model(requests)
        await vm.loadAllRequests()
        #expect(vm.allRequestsError != nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.allRequests.isEmpty)

        requests.failQueue = false
        await vm.loadAllRequests()
        #expect(vm.allRequestsError == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A failed approve changes nothing, so it must not put an older list back (CAT-207, R-CATALOG-6).
    @Test func aFailedApproveLeavesTheCurrentListAlone() async {
        let requests = Requests()
        requests.queue[.pending] = [request(1), request(2)]
        requests.queue[.approved] = [request(3)]
        let vm = model(requests)
        await vm.loadAllRequests()

        let approve = Task { await vm.approveRequest(vm.allRequests[0]) }
        await waitUntil { requests.started.contains("approve") }
        await vm.setAllRequestsFilter(.approved)
        requests.open = true
        await approve.value

        #expect(vm.allRequests.map(\.id) == [3])
    }

    /// A failed delete puts back the one row it took out, not the whole older list.
    @Test func aFailedDeleteReinsertsOnlyItsRowAndKeepsLaterChanges() async {
        let requests = Requests()
        requests.queue[.pending] = [request(1), request(2), request(3)]
        let vm = model(requests)
        await vm.loadAllRequests()

        let delete = Task { await vm.deleteRequest(vm.allRequests[1]) }
        await waitUntil { requests.started.contains("delete") }
        #expect(vm.allRequests.map(\.id) == [1, 3])
        requests.open = true
        await delete.value

        #expect(vm.allRequests.map(\.id) == [1, 2, 3])
    }

    @Test func aFailedDeleteDoesNotTouchAListAReloadReplaced() async {
        let requests = Requests()
        requests.queue[.pending] = [request(1), request(2)]
        requests.queue[.approved] = [request(3)]
        let vm = model(requests)
        await vm.loadAllRequests()

        let delete = Task { await vm.deleteRequest(vm.allRequests[0]) }
        await waitUntil { requests.started.contains("delete") }
        await vm.setAllRequestsFilter(.approved)
        requests.open = true
        await delete.value

        #expect(vm.allRequests.map(\.id) == [3])
    }
}

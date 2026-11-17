import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-11-17 CAT-201 and CAT-202. One Trakt connection per profile: an answer that lands after a
/// profile switch has to be written to the profile it was started for, and marking a whole series or
/// season watched must not send a show-level add (Trakt stamps a new play on every aired episode).
@MainActor
@Suite(.serialized)
struct TraktProfileBindingTests {

    // MARK: - Doubles

    nonisolated final class Wire: @unchecked Sendable {
        static let shared = Wire()
        private let lock = NSLock()
        private var _requests: [String] = []
        private var _held: [TraktStubProtocol] = []
        private var _holdPaths: Set<String> = []

        func reset(hold: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            _requests = []; _held = []; _holdPaths = hold
        }
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return _held.count }

        func arrive(_ proto: TraktStubProtocol, method: String, path: String) {
            lock.lock()
            _requests.append("\(method) \(path)")
            let hold = _holdPaths.contains(path)
            if hold { _held.append(proto) }
            lock.unlock()
            if !hold { proto.answer(path: path) }
        }

        func releaseHeld() {
            lock.lock(); let held = _held; _held = []; lock.unlock()
            for proto in held { proto.answer(path: proto.request.url?.path ?? "") }
        }
    }

    nonisolated final class TraktStubProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Wire.shared.arrive(self, method: request.httpMethod ?? "GET", path: request.url?.path ?? "")
        }
        override func stopLoading() {}

        func answer(path: String) {
            let body: String
            var status = 200
            switch path {
            case "/oauth/token":
                body = #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":604800,"created_at":\#(Int(Date().timeIntervalSince1970))}"#
            case "/sync/watchlist", "/oauth/revoke":
                body = "{}"
            default:
                body = "{}"; status = 404
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    final class MemoryStore: TraktSessionStoring {
        var sessions: [ProfileKey: TraktSession] = [:]
        func loadTraktSession(for profile: ProfileKey) -> TraktSession? { sessions[profile] }
        func saveTraktSession(_ session: TraktSession, for profile: ProfileKey) { sessions[profile] = session }
        func deleteTraktSession(for profile: ProfileKey) { sessions[profile] = nil }
    }

    struct NotUsed: Error {}

    final class Library: JellyfinLibraryServiceProtocol, @unchecked Sendable {
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getResumeItems(userID: String, mediaType: String, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getNextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getLatestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int) async throws -> [JellyfinItem] { [] }
        func getGenres(userID: String) async throws -> [NamedItem] { [] }
        func getStudios(userID: String) async throws -> [NamedItem] { [] }
    }

    final class Items: JellyfinItemServiceProtocol, @unchecked Sendable {
        func getItemDetail(userID: String, itemID: String) async throws -> JellyfinItem { throw NotUsed() }
        func getLocalTrailers(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSpecialFeatures(userID: String, itemID: String) async throws -> [JellyfinItem] { [] }
        func getSeasons(seriesID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getSimilarItems(itemID: String, userID: String, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func getPlaylistItems(playlistID: String, userID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func setFavorite(userID: String, itemID: String, isFavorite: Bool) async throws {}
        func setPlayed(userID: String, itemID: String, isPlayed: Bool) async throws {}
        func setRating(userID: String, itemID: String, rating: Double?) async throws {}
        func clearPlaybackPosition(userID: String, itemID: String) async throws {}
        func getCollectionItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse { throw NotUsed() }
        func findByTmdbID(userID: String, tmdbID: Int, searchTerm: String?) async throws -> JellyfinItem? { nil }
        func findByProviderIDs(userID: String, tmdbID: Int?, tvdbID: Int?, imdbID: String?, includeItemTypes: [ItemType], searchTerm: String?) async throws -> JellyfinItem? { nil }
        func searchPersons(userID: String, name: String, limit: Int) async throws -> [JellyfinItem] { [] }
        func deleteItem(itemID: String) async throws {}
    }

    private let profileA = ProfileKey(serverID: "srv", userID: "userA")
    private let profileB = ProfileKey(serverID: "srv", userID: "userB")

    private func session(_ tag: String, expiresIn: TimeInterval) -> TraktSession {
        TraktSession(tokens: TraktTokens(accessToken: "access-\(tag)", refreshToken: "refresh-\(tag)",
                                         expiresAt: Date().addingTimeInterval(expiresIn)),
                     username: tag, isVIP: false,
                     cursors: TraktSyncCursors(lastSyncAt: Date()))
    }

    private func makeService(store: MemoryStore) -> TraktService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraktStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config))
        return TraktService(clientID: "test", store: store, libraryService: Library(), itemService: Items(),
                            makeClient: { TraktClient(clientID: $0, http: http) })
    }

    private func item(_ type: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"i1","Name":"Title","Type":"\#(type)","ProviderIds":{"Tmdb":"603"}}"#.utf8))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - CAT-201

    @Test func aRefreshThatLandsAfterASwitchIsSavedForItsOwnProfile() async throws {
        Wire.shared.reset(hold: ["/oauth/token"])
        let store = MemoryStore()
        store.sessions[profileA] = session("A", expiresIn: 60)
        store.sessions[profileB] = session("B", expiresIn: 3 * 24 * 3600)
        let service = makeService(store: store)
        service.activate(profile: profileA)

        let write = Task { try await service.setOnWatchlist(try item("Movie"), true) }
        await waitUntil { Wire.shared.heldCount == 1 }
        service.activate(profile: profileB)
        Wire.shared.releaseHeld()
        _ = try? await write.value

        #expect(store.sessions[profileA]?.tokens.accessToken == "fresh-access")
        #expect(store.sessions[profileA]?.tokens.refreshToken == "fresh-refresh")
        #expect(store.sessions[profileB]?.tokens.accessToken == "access-B")
        #expect(store.sessions[profileB]?.tokens.refreshToken == "refresh-B")
        #expect(service.session?.username == "B")
    }

    @Test func aDisconnectThatFinishesAfterASwitchLeavesTheNewProfileConnected() async {
        Wire.shared.reset(hold: ["/oauth/revoke"])
        let store = MemoryStore()
        store.sessions[profileA] = session("A", expiresIn: 3 * 24 * 3600)
        store.sessions[profileB] = session("B", expiresIn: 3 * 24 * 3600)
        let service = makeService(store: store)
        service.activate(profile: profileA)

        let disconnect = Task { await service.disconnect() }
        await waitUntil { Wire.shared.heldCount == 1 }
        service.activate(profile: profileB)
        Wire.shared.releaseHeld()
        await disconnect.value

        #expect(store.sessions[profileA] == nil)
        #expect(store.sessions[profileB]?.username == "B")
        #expect(service.session?.username == "B")
        #expect(service.isConnected)
    }

    // MARK: - CAT-202

    @Test func markingASeriesWatchedSendsNoShowLevelAdd() async throws {
        Wire.shared.reset(hold: [])
        let store = MemoryStore()
        store.sessions[profileA] = session("A", expiresIn: 3 * 24 * 3600)
        let service = makeService(store: store)
        service.activate(profile: profileA)

        service.playedChanged(for: try item("Series"), played: true)
        service.playedChanged(for: try item("Series"), played: true, seasonNumber: 2)
        try? await Task.sleep(for: .milliseconds(300))

        #expect(!Wire.shared.requests.contains { $0.hasSuffix("/sync/history") })
    }

    @Test func unwatchingASeasonStillRemovesTheWholeSeason() {
        let show = TraktService.wholeShowOrSeason(ids: TraktIDs(imdb: nil, tmdb: 603, tvdb: nil), seasonNumber: 2)
        #expect(show.seasons == [.init(number: 2, episodes: nil)])
    }
}

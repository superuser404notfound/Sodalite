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
        private var _bodies: [String: [String]] = [:]
        private var _held: [TraktStubProtocol] = []
        private var _holdPaths: Set<String> = []

        func reset(hold: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            _requests = []; _bodies = [:]; _held = []; _holdPaths = hold
        }
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
        var heldCount: Int { lock.lock(); defer { lock.unlock() }; return _held.count }
        func count(_ request: String) -> Int { requests.filter { $0 == request }.count }
        func bodies(_ request: String) -> [String] { lock.lock(); defer { lock.unlock() }; return _bodies[request] ?? [] }

        func arrive(_ proto: TraktStubProtocol, method: String, path: String, body: String) {
            let key = "\(method) \(path)"
            lock.lock()
            _requests.append(key)
            _bodies[key, default: []].append(body)
            let hold = _holdPaths.contains(path)
            if hold { _held.append(proto) }
            lock.unlock()
            if !hold { proto.answerNow() }
        }

        func releaseHeld() {
            lock.lock(); let held = _held; _held = []; lock.unlock()
            for proto in held { proto.answerOnLoadingThread() }
        }
    }

    nonisolated final class TraktStubProtocol: URLProtocol, @unchecked Sendable {
        private var loadingThread: Thread?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            loadingThread = Thread.current
            Wire.shared.arrive(self, method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                               body: Self.bodyText(request))
        }
        override func stopLoading() {}

        private static func bodyText(_ request: URLRequest) -> String {
            if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
            guard let stream = request.httpBodyStream else { return "" }
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return String(decoding: data, as: UTF8.self)
        }

        /// URLProtocol callbacks belong to the thread that ran `startLoading`.
        func answerOnLoadingThread() {
            if let loadingThread, loadingThread != Thread.current {
                perform(#selector(answerNow), on: loadingThread, with: nil, waitUntilDone: false)
            } else {
                answerNow()
            }
        }

        @objc func answerNow() {
            let path = request.url?.path ?? ""
            var body = "{}"
            var status = 200
            switch path {
            case "/oauth/token":
                body = #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":604800,"created_at":\#(Int(Date().timeIntervalSince1970))}"#
            case "/users/me/watched/movies", "/users/me/watched/shows", "/users/me/lists":
                body = "[]"
            case _ where path.hasPrefix("/sync/watchlist/movie"):
                body = "[]"
            case "/sync/watchlist", "/oauth/revoke", "/sync/last_activities", "/sync/history", "/sync/history/remove":
                body = "{}"
            default:
                status = 404
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
        var series: [JellyfinItem] = []
        var episodes: [JellyfinItem] = []
        func getLibraries(userID: String) async throws -> [JellyfinLibrary] { [] }
        func getItems(userID: String, query: ItemQuery) async throws -> JellyfinItemsResponse {
            let items = query.includeItemTypes?.contains(.series) == true ? series
                : query.includeItemTypes?.contains(.episode) == true ? episodes : []
            let json = try JSONEncoder().encode(items)
            return try JSONDecoder().decode(JellyfinItemsResponse.self,
                from: Data(#"{"Items":\#(String(decoding: json, as: UTF8.self)),"TotalRecordCount":\#(items.count)}"#.utf8))
        }
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

    private func session(_ tag: String, expiresIn: TimeInterval, options: TraktOptions = TraktOptions()) -> TraktSession {
        TraktSession(tokens: TraktTokens(accessToken: "access-\(tag)", refreshToken: "refresh-\(tag)",
                                         expiresAt: Date().addingTimeInterval(expiresIn)),
                     username: tag, isVIP: false, options: options,
                     cursors: TraktSyncCursors(lastSyncAt: Date()))
    }

    private func makeService(store: MemoryStore, library: Library = Library()) -> TraktService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraktStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config))
        return TraktService(clientID: "test", store: store, libraryService: library, itemService: Items(),
                            makeClient: { TraktClient(clientID: $0, http: http) })
    }

    private func item(_ type: String, id: String = "i1") throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"Title","Type":"\#(type)","ProviderIds":{"Tmdb":"603"}}"#.utf8))
    }

    private func episode(_ id: String, number: Int, playedDaysAgo: Double) throws -> JellyfinItem {
        let date = TraktDate.wire(Date().addingTimeInterval(-playedDaysAgo * 86_400))
        return try JSONDecoder().decode(JellyfinItem.self, from: Data(
            #"{"Id":"\#(id)","Name":"E\#(number)","Type":"Episode","SeriesId":"s1","ParentIndexNumber":1,"IndexNumber":\#(number),"UserData":{"PlaybackPositionTicks":0,"PlayCount":1,"IsFavorite":false,"Played":true,"LastPlayedDate":"\#(date)"}}"#.utf8))
    }

    /// Bounded: a regression fails the test instead of hanging it.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - CAT-201

    @Test func aRefreshThatLandsAfterASwitchIsSavedForItsOwnProfile() async throws {
        Wire.shared.reset(hold: ["/oauth/token"])
        let store = MemoryStore()
        store.sessions[profileA] = session("A", expiresIn: 60)
        store.sessions[profileB] = session("B", expiresIn: 3 * 24 * 3600)
        let service = makeService(store: store)
        service.activate(profile: profileA)

        var finished = false
        let movie = try item("Movie")
        Task { _ = try? await service.setOnWatchlist(movie, true); finished = true }
        await waitUntil { Wire.shared.heldCount == 1 }
        service.activate(profile: profileB)
        Wire.shared.releaseHeld()
        await waitUntil { finished }

        #expect(store.sessions[profileA]?.tokens.accessToken == "fresh-access")
        #expect(store.sessions[profileA]?.tokens.refreshToken == "fresh-refresh")
        #expect(store.sessions[profileB]?.tokens.accessToken == "access-B")
        #expect(store.sessions[profileB]?.tokens.refreshToken == "refresh-B")
        #expect(service.session?.username == "B")
    }

    /// Review R-CATALOG-3. A, then B, then A inside one refresh: the second activation must find the
    /// first one's client, or two refreshes spend one single-use token.
    @Test func switchingAwayAndBackDuringARefreshSpendsTheTokenOnce() async throws {
        Wire.shared.reset(hold: ["/oauth/token"])
        let store = MemoryStore()
        store.sessions[profileA] = session("A", expiresIn: 60)
        store.sessions[profileB] = session("B", expiresIn: 3 * 24 * 3600)
        let service = makeService(store: store)
        service.activate(profile: profileA)

        var firstDone = false, secondDone = false
        let movie = try item("Movie")
        Task { _ = try? await service.setOnWatchlist(movie, true); firstDone = true }
        await waitUntil { Wire.shared.heldCount == 1 }
        service.activate(profile: profileB)
        service.activate(profile: profileA)
        Task { _ = try? await service.setOnWatchlist(movie, false); secondDone = true }
        try await Task.sleep(for: .milliseconds(100))
        Wire.shared.releaseHeld()
        await waitUntil { firstDone && secondDone }

        #expect(Wire.shared.count("POST /oauth/token") == 1)
        #expect(store.sessions[profileA]?.tokens.accessToken == "fresh-access")
        #expect(service.isConnected)
        #expect(service.session?.username == "A")
    }

    @Test func aDisconnectThatFinishesAfterASwitchLeavesTheNewProfileConnected() async {
        Wire.shared.reset(hold: ["/oauth/revoke"])
        let store = MemoryStore()
        store.sessions[profileA] = session("A", expiresIn: 3 * 24 * 3600)
        store.sessions[profileB] = session("B", expiresIn: 3 * 24 * 3600)
        let service = makeService(store: store)
        service.activate(profile: profileA)

        var finished = false
        Task { await service.disconnect(); finished = true }
        await waitUntil { Wire.shared.heldCount == 1 }
        service.activate(profile: profileB)
        Wire.shared.releaseHeld()
        await waitUntil { finished }

        #expect(store.sessions[profileA] == nil)
        #expect(store.sessions[profileB]?.username == "B")
        #expect(service.session?.username == "B")
        #expect(service.isConnected)
    }

    // MARK: - CAT-202 and review R-CATALOG-1, R-CATALOG-2

    /// Mark a series watched, unmark it, mark it again. Each mark must reach Trakt as dated episode
    /// adds (never a show-level add), including the episode whose old part-watch date lies outside the
    /// push window, and the unmark must clear what was recorded as sent.
    @Test func markUnmarkMarkAgainSendsTheEpisodesEachTime() async throws {
        Wire.shared.reset(hold: [])
        let profile = ProfileKey(serverID: "srv-\(UUID().uuidString)", userID: "u")
        defer { TraktCacheStore.removeAll(profile) }
        var options = TraktOptions()
        options.syncRatings = false
        let store = MemoryStore()
        store.sessions[profile] = session("A", expiresIn: 3 * 24 * 3600, options: options)
        let library = Library()
        library.series = [try item("Series", id: "s1")]
        library.episodes = [try episode("e1", number: 1, playedDaysAgo: 0), try episode("e2", number: 2, playedDaysAgo: 30)]
        let service = makeService(store: store, library: library)
        service.activate(profile: profile)
        let series = try item("Series", id: "s1")

        service.playedChanged(for: series, played: true)
        await waitUntil { Wire.shared.count("POST /sync/history") == 1 && !service.isSyncing }
        let firstAdd = Wire.shared.bodies("POST /sync/history").first ?? ""
        #expect(firstAdd.contains("\"number\":1") && firstAdd.contains("\"number\":2"))
        #expect(!firstAdd.contains("\"seasons\":null"))

        service.playedChanged(for: series, played: false)
        await waitUntil { Wire.shared.count("POST /sync/history/remove") == 1 }
        await waitUntil {
            TraktCacheStore.load(TraktWatchedSnapshot.self, name: TraktCacheStore.watched, profile: profile)?.pushed.isEmpty == true
        }

        service.playedChanged(for: series, played: true)
        await waitUntil { Wire.shared.count("POST /sync/history") == 2 }
        #expect(Wire.shared.count("POST /sync/history") == 2)
    }

    @Test func unwatchingASeasonStillRemovesTheWholeSeason() {
        let show = TraktService.wholeShowOrSeason(ids: TraktIDs(imdb: nil, tmdb: 603, tvdb: nil), seasonNumber: 2)
        #expect(show.seasons == [.init(number: 2, episodes: nil)])
    }

    // MARK: - CAT-209

    @Test func aKnownLastSyncKeepsTheWindowsEvenWithoutACache() {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = TraktService.watchedWindows(lastSyncAt: last)
        #expect(windows.isFirst == false)
        #expect(windows.pullSince == last.addingTimeInterval(-86_400))
        #expect(windows.pushSince == last.addingTimeInterval(-7 * 86_400))

        let first = TraktService.watchedWindows(lastSyncAt: nil)
        #expect(first.isFirst && first.pullSince == nil && first.pushSince == nil)
    }
}

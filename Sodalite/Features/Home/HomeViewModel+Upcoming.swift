import Foundation

// MARK: - Upcoming Row (Sodalite#198)

extension HomeViewModel {

    /// The library's schedule first, then the server's own Upcoming list, then Seerr for the
    /// caught-up shows neither said anything about. Seerr belongs to the active session, so a
    /// combined Home's secondary gets the server passes only.
    func loadUpcoming(source: HomeSource) async throws -> [JellyfinItem] {
        let now = Date()
        let calendar = Calendar.current
        async let playedResponse = source.libraryService.getItems(
            userID: source.userID, query: HomeUpcoming.recentlyPlayedQuery()
        )
        async let nextUpResponse = source.libraryService.getNextUp(
            userID: source.userID, seriesID: nil, limit: 100, rewatching: false
        )
        async let scheduleResponse = source.libraryService.getItems(
            userID: source.userID, query: HomeUpcoming.scheduleQuery(now: now, limit: HomeUpcoming.scheduleLimit)
        )
        async let serverListResponse = source.libraryService.getUpcoming(
            userID: source.userID, limit: HomeUpcoming.serverListLimit
        )
        // Next Up must answer: without it every watched show would read as caught up.
        let caughtUp = HomeUpcoming.caughtUpSeries(
            recentlyPlayed: try await playedResponse.items,
            nextUp: try await nextUpResponse.items
        )
        let schedule = (try? await scheduleResponse)?.items ?? []
        var found = HomeUpcoming.fromLibrary(schedule, caughtUp: caughtUp, now: now, calendar: calendar)
        if !found.isEmpty {
            let query = ItemQuery(ids: found.map(\.id), fields: JellyfinEndpoint.homeRowFields)
            if let detailed = try? await source.libraryService.getItems(userID: source.userID, query: query).items {
                let byID = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                found = found.map { byID[$0.id] ?? $0 }
            }
        }

        let serverList = (try? await serverListResponse) ?? []
        found += HomeUpcoming.fromServerList(serverList, found: found, caughtUp: caughtUp, now: now, calendar: calendar)

        let missing = HomeUpcoming.needingLookup(caughtUp: caughtUp, found: found)
        if source.isActive, let lookup = nextAiringLookup, !missing.isEmpty {
            found += await seerrUpcoming(for: missing, source: source, lookup: lookup, now: now, calendar: calendar)
        }
        return HomeUpcoming.ordered(DroppedSeriesStore.filter(found, serverID: source.serverID, scope: homeScope))
    }

    private nonisolated static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func seerrUpcoming(
        for seriesIDs: [String],
        source: HomeSource,
        lookup: @escaping @Sendable (Int) async throws -> SeerrEpisode?,
        now: Date,
        calendar: Calendar
    ) async -> [JellyfinItem] {
        let query = ItemQuery(ids: seriesIDs, fields: JellyfinEndpoint.homeRowFields)
        guard let series = try? await source.libraryService.getItems(userID: source.userID, query: query).items
        else { return [] }
        let candidates = series.filter(HomeUpcoming.isLookupCandidate)
        let tmdbIDs = Set(candidates.compactMap(\.tmdbID))

        var answers: [Int: SeerrEpisode?] = [:]
        var stale: [Int] = []
        for id in tmdbIDs {
            if let cached = nextAiringCache[id], now.timeIntervalSince(cached.fetchedAt) < HomeUpcoming.lookupLifetime {
                answers[id] = cached.episode
            } else {
                stale.append(id)
            }
        }

        // Bounded like the genre probes, so a long watch history cannot burst Seerr's limiter. A
        // failed request is neither shown nor remembered. It stays a Result: `try?` on an optional
        // result flattens, and a thrown error then cached "no next episode" for six hours (BRW-202).
        typealias Answer = Result<SeerrEpisode?, Error>
        let fetched: [(Int, Answer)] = await withTaskGroup(of: (Int, Answer).self) { group in
            var pending = stale.makeIterator()
            for _ in 0..<4 {
                guard let id = pending.next() else { break }
                group.addTask { (id, await Self.attempt { try await lookup(id) }) }
            }
            var results: [(Int, Answer)] = []
            for await result in group {
                results.append(result)
                if let id = pending.next() { group.addTask { (id, await Self.attempt { try await lookup(id) }) } }
            }
            return results
        }
        for (id, answer) in fetched {
            guard case .success(let episode) = answer else { continue }
            answers[id] = episode
            nextAiringCache[id] = HomeUpcoming.CachedAiring(episode: episode, fetchedAt: now)
        }

        return candidates.compactMap { series in
            guard let id = series.tmdbID, let episode = answers[id] else { return nil }
            return HomeUpcoming.fromSeerr(series: series, episode: episode, now: now, calendar: calendar)
        }
    }
}

/// Thrown by the Upcoming lookup while there is no Seerr session, so "not asked yet" is not
/// remembered as "nothing announced" (BRW-202).
struct SeerrLookupUnavailable: Error {}

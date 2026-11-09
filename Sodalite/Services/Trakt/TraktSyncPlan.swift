import Foundation

/// A library item reduced to what the sync compares.
nonisolated struct TraktLocalMovie: Sendable, Equatable {
    let itemID: String
    let ids: TraktIDs
    let played: Bool
    let lastPlayed: Date?
    let rating: Double?
}

nonisolated struct TraktLocalSeries: Sendable, Equatable {
    let itemID: String
    let ids: TraktIDs
    let rating: Double?
}

nonisolated struct TraktLocalEpisode: Sendable, Equatable {
    let itemID: String
    let seriesID: String
    let season: Int
    let number: Int
    let played: Bool
    let lastPlayed: Date?
}

/// Lookup keys for an id set, one per external id. Two records are the same title when any key
/// matches: Jellyfin and Trakt rarely carry the same subset, and every one of these ids is unique
/// within its kind.
nonisolated enum TraktKey {
    static func keys(_ ids: TraktIDs) -> [String] {
        var keys: [String] = []
        if let tmdb = ids.tmdb { keys.append("tmdb:\(tmdb)") }
        if let imdb = ids.imdb, !imdb.isEmpty { keys.append("imdb:\(imdb.lowercased())") }
        if let tvdb = ids.tvdb { keys.append("tvdb:\(tvdb)") }
        return keys
    }

    static func episode(showKey: String, season: Int, number: Int) -> String {
        "\(showKey)|\(season)|\(number)"
    }
}

/// What Trakt says the user has watched, flattened to keys. Cached between syncs so a sync whose
/// Trakt side did not move costs one `last_activities` call instead of the whole history.
nonisolated struct TraktWatchedSnapshot: Codable, Sendable, Equatable {
    var movies: Set<String> = []
    var episodes: Set<String> = []
    /// Everything Sodalite sent to Trakt's history, kept across rebuilds. Trakt does not take every
    /// entry (an episode its numbering does not have), and without this the sync would send the
    /// same rejected entries again on every run. Measured on the first device test: every sync
    /// reported a push.
    var pushed: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movies = try c.decodeIfPresent(Set<String>.self, forKey: .movies) ?? []
        episodes = try c.decodeIfPresent(Set<String>.self, forKey: .episodes) ?? []
        pushed = try c.decodeIfPresent(Set<String>.self, forKey: .pushed) ?? []
    }

    /// `since` keeps only watches newer than it: the pull side uses that, so a title someone marked
    /// unwatched in Jellyfin is not marked watched again by an old Trakt entry on the next sync.
    init(movies: [TraktWatchedMovie], shows: [TraktWatchedShow], since: Date? = nil) {
        func isRecent(_ date: Date?) -> Bool {
            guard let since else { return true }
            return (date ?? .distantPast) >= since
        }
        for entry in movies where isRecent(entry.lastWatchedAt) {
            self.movies.formUnion(TraktKey.keys(entry.movie.ids))
        }
        for entry in shows {
            for showKey in TraktKey.keys(entry.show.ids) {
                for season in entry.seasons ?? [] {
                    for episode in season.episodes where isRecent(episode.lastWatchedAt) {
                        episodes.insert(TraktKey.episode(showKey: showKey, season: season.number,
                                                         number: episode.number))
                    }
                }
            }
        }
    }

    func contains(movie ids: TraktIDs) -> Bool {
        TraktKey.keys(ids).contains { movies.contains($0) || pushed.contains("m|" + $0) }
    }

    func contains(episodeOf seriesIDs: TraktIDs, season: Int, number: Int) -> Bool {
        TraktKey.keys(seriesIDs).contains {
            let key = TraktKey.episode(showKey: $0, season: season, number: number)
            return episodes.contains(key) || pushed.contains("e|" + key)
        }
    }

    /// The movie and episode keys a body addresses. A season or show without episodes addresses
    /// nothing here: those are only ever removals.
    private static func keys(of body: TraktSyncBody) -> (movies: [String], episodes: [String]) {
        let movieKeys = body.movies.flatMap { TraktKey.keys($0.ids) }
        var episodeKeys: [String] = []
        for show in body.shows {
            for showKey in TraktKey.keys(show.ids) {
                for season in show.seasons ?? [] {
                    for episode in season.episodes ?? [] {
                        episodeKeys.append(TraktKey.episode(showKey: showKey, season: season.number,
                                                            number: episode.number))
                    }
                }
            }
        }
        return (movieKeys, episodeKeys)
    }

    mutating func record(_ body: TraktSyncBody) {
        let (movieKeys, episodeKeys) = Self.keys(of: body)
        movies.formUnion(movieKeys)
        episodes.formUnion(episodeKeys)
        pushed.formUnion(movieKeys.map { "m|" + $0 } + episodeKeys.map { "e|" + $0 })
    }

    /// The viewer unwatched these in Sodalite, so a later watch must be sent again.
    mutating func forget(_ body: TraktSyncBody) {
        let (movieKeys, episodeKeys) = Self.keys(of: body)
        movies.subtract(movieKeys)
        episodes.subtract(episodeKeys)
        pushed.subtract(movieKeys.map { "m|" + $0 } + episodeKeys.map { "e|" + $0 })
    }
}

/// The two-way watched merge. Additive in both directions: something watched on either side ends up
/// watched on both, and nothing is ever marked unwatched. That makes the first sync of a long
/// history as safe as the hundredth, and a sync that runs twice harmless.
nonisolated enum TraktSyncPlan {

    struct Watched: Equatable {
        /// Jellyfin items to mark played.
        var markPlayed: [String] = []
        /// History Trakt is missing.
        var push = TraktSyncBody()
    }

    /// - Parameters:
    ///   - trakt: everything Trakt has as watched; nothing in it is pushed again.
    ///   - pull: the Trakt watches to bring into Jellyfin, already cut to the recent ones. nil when
    ///     the caller fetched only played items, so there is nothing unplayed to pull into.
    ///   - pushSince: only local watches at or after this go to Trakt; nil pushes all of them (the
    ///     first sync). Keeps a watch someone deleted on Trakt from coming straight back.
    static func watched(
        movies: [TraktLocalMovie],
        series: [TraktLocalSeries],
        episodes: [TraktLocalEpisode],
        trakt: TraktWatchedSnapshot,
        pull: TraktWatchedSnapshot?,
        pushSince: Date?
    ) -> Watched {
        var plan = Watched()
        func pushable(_ lastPlayed: Date?) -> Bool {
            guard let pushSince else { return true }
            return (lastPlayed ?? .distantPast) >= pushSince
        }

        for movie in movies where !movie.ids.isEmpty {
            if movie.played {
                if !trakt.contains(movie: movie.ids), pushable(movie.lastPlayed) {
                    plan.push.movies.append(.init(ids: movie.ids.external, watchedAt: TraktDate.wire(movie.lastPlayed)))
                }
            } else if pull?.contains(movie: movie.ids) == true {
                plan.markPlayed.append(movie.itemID)
            }
        }

        let seriesByID = Dictionary(series.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        var pushBySeries: [String: [Int: [TraktSyncBody.Show.Season.Episode]]] = [:]
        for episode in episodes {
            guard let show = seriesByID[episode.seriesID], !show.ids.isEmpty else { continue }
            if episode.played {
                let onTrakt = trakt.contains(episodeOf: show.ids, season: episode.season, number: episode.number)
                if !onTrakt, pushable(episode.lastPlayed) {
                    pushBySeries[show.itemID, default: [:]][episode.season, default: []]
                        .append(.init(number: episode.number, watchedAt: TraktDate.wire(episode.lastPlayed)))
                }
            } else if pull?.contains(episodeOf: show.ids, season: episode.season, number: episode.number) == true {
                plan.markPlayed.append(episode.itemID)
            }
        }
        for seriesID in pushBySeries.keys.sorted() {
            guard let show = seriesByID[seriesID], let seasons = pushBySeries[seriesID] else { continue }
            plan.push.shows.append(.init(
                ids: show.ids.external,
                seasons: seasons.keys.sorted().map { .init(number: $0, episodes: seasons[$0] ?? []) }
            ))
        }
        return plan
    }

    struct Ratings: Equatable {
        var setLocal: [String: Double] = [:]
        var push = TraktSyncBody()
    }

    /// Fills the side that has no rating from the side that has one. A title rated on both sides is
    /// left alone: neither carries a timestamp Sodalite could trust to say which is newer, and a
    /// live change in Sodalite already reaches Trakt the moment it is made.
    static func ratings(
        movies: [TraktLocalMovie],
        series: [TraktLocalSeries],
        traktRatings: [TraktRatedItem]
    ) -> Ratings {
        var traktMovies: [String: Int] = [:]
        var traktShows: [String: Int] = [:]
        for rated in traktRatings {
            if let movie = rated.movie {
                for key in TraktKey.keys(movie.ids) { traktMovies[key] = rated.rating }
            } else if let show = rated.show {
                for key in TraktKey.keys(show.ids) { traktShows[key] = rated.rating }
            }
        }

        var plan = Ratings()
        for movie in movies where !movie.ids.isEmpty {
            let remote = TraktKey.keys(movie.ids).lazy.compactMap { traktMovies[$0] }.first
            switch (TraktRating.trakt(fromJellyfin: movie.rating), remote) {
            case (nil, let remote?): plan.setLocal[movie.itemID] = Double(remote)
            case (let local?, nil): plan.push.movies.append(.init(ids: movie.ids.external, rating: local))
            default: break
            }
        }
        for show in series where !show.ids.isEmpty {
            let remote = TraktKey.keys(show.ids).lazy.compactMap { traktShows[$0] }.first
            switch (TraktRating.trakt(fromJellyfin: show.rating), remote) {
            case (nil, let remote?): plan.setLocal[show.itemID] = Double(remote)
            case (let local?, nil): plan.push.shows.append(.init(ids: show.ids.external, rating: local))
            default: break
            }
        }
        return plan
    }

    /// Splits a body into chunks Trakt takes in one request without timing out.
    static func batches(_ body: TraktSyncBody, size: Int = 200) -> [TraktSyncBody] {
        var result: [TraktSyncBody] = []
        var current = TraktSyncBody()
        var count = 0
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = TraktSyncBody()
            count = 0
        }
        for movie in body.movies {
            current.movies.append(movie)
            count += 1
            if count >= size { flush() }
        }
        for show in body.shows {
            current.shows.append(show)
            count += show.seasons?.reduce(0) { $0 + ($1.episodes?.count ?? 1) } ?? 1
            if count >= size { flush() }
        }
        for episode in body.episodes {
            current.episodes.append(episode)
            count += 1
            if count >= size { flush() }
        }
        flush()
        return result
    }
}

nonisolated enum TraktRating {
    /// Jellyfin stores 0 to 10 in steps Sodalite writes as whole stars; Trakt takes 1 to 10.
    /// 0 or nil is "not rated".
    static func trakt(fromJellyfin rating: Double?) -> Int? {
        guard let rating, rating >= 0.5 else { return nil }
        return min(10, max(1, Int(rating.rounded())))
    }
}

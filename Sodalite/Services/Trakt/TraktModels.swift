import Foundation

/// The id set Trakt uses for every movie, show and episode. Any one of them identifies the item, so
/// Sodalite sends whatever the Jellyfin item carries and lets Trakt resolve it.
nonisolated struct TraktIDs: Codable, Sendable, Hashable {
    var trakt: Int?
    var slug: String?
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?

    init(trakt: Int? = nil, slug: String? = nil, imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.trakt = trakt
        self.slug = slug
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    /// The ids a Jellyfin item carries, or nil when it has none Trakt understands.
    @MainActor init?(item: JellyfinItem) {
        self.init(imdb: item.imdbID, tmdb: item.tmdbID, tvdb: item.tvdbID)
        if isEmpty { return nil }
    }

    var isEmpty: Bool { imdb == nil && tmdb == nil && tvdb == nil && trakt == nil }

    /// Only the external ids, which is all a write needs and keeps a body small.
    var external: TraktIDs { TraktIDs(imdb: imdb, tmdb: tmdb, tvdb: tvdb) }
}

/// Only the poster is read. Trakt serves WebP without a scheme, and forbids hotlinking: every image
/// has to go through a cache, which `AsyncCachedImage` is.
nonisolated struct TraktImages: Codable, Sendable, Hashable {
    var poster: [String]?

    var posterURL: URL? {
        guard let path = poster?.first, !path.isEmpty else { return nil }
        return URL(string: path.hasPrefix("http") ? path : "https://\(path)")
    }
}

nonisolated struct TraktMovie: Codable, Sendable, Hashable {
    var title: String?
    var year: Int?
    var ids: TraktIDs
    var images: TraktImages?
}

nonisolated struct TraktShow: Codable, Sendable, Hashable {
    var title: String?
    var year: Int?
    var ids: TraktIDs
    var images: TraktImages?
}

nonisolated struct TraktEpisode: Codable, Sendable, Hashable {
    var season: Int?
    var number: Int?
    var title: String?
    var ids: TraktIDs?
}

// MARK: - OAuth

nonisolated struct TraktDeviceCode: Decodable, Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int
}

nonisolated struct TraktTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let createdAt: Int
}

// MARK: - Account

nonisolated struct TraktUserSettings: Decodable, Sendable {
    struct User: Decodable, Sendable {
        let username: String
        let name: String?
        let vip: Bool?
        let ids: TraktIDs?
    }
    struct Limits: Decodable, Sendable {
        struct List: Decodable, Sendable {
            let count: Int?
            let itemCount: Int?
        }
        struct Watchlist: Decodable, Sendable {
            let itemCount: Int?
        }
        let list: List?
        let watchlist: Watchlist?
    }
    let user: User
    let limits: Limits?
}

// MARK: - Sync

/// The timestamps Trakt moves whenever something of that kind changes. Every field is optional:
/// the response has grown over the years, and a missing one only costs a fetch.
nonisolated struct TraktLastActivities: Decodable, Sendable {
    struct Kind: Decodable, Sendable {
        let watchedAt: Date?
        let ratedAt: Date?
        let watchlistedAt: Date?
    }
    struct Updated: Decodable, Sendable {
        let updatedAt: Date?
    }
    let all: Date?
    let movies: Kind?
    let episodes: Kind?
    let shows: Kind?
    let watchlist: Updated?
    let lists: Updated?
}

nonisolated struct TraktWatchedMovie: Decodable, Sendable {
    let lastWatchedAt: Date?
    let movie: TraktMovie
}

/// A show from `/users/me/watched/shows`. Trakt no longer sends `seasons` there (measured on the
/// first device test: 18 shows, `"plays":38` and no seasons key), so the episodes come from each
/// show's progress (`TraktShowProgress`) and are filled in by the sync.
nonisolated struct TraktWatchedShow: Decodable, Sendable {
    struct Season: Codable, Sendable, Equatable {
        struct Episode: Codable, Sendable, Equatable {
            let number: Int
            let lastWatchedAt: Date?
        }
        let number: Int
        let episodes: [Episode]
    }
    var plays: Int?
    var lastWatchedAt: Date?
    let show: TraktShow
    var seasons: [Season]?
}

/// `/shows/{id}/progress/watched`: every aired episode with whether the user completed it.
nonisolated struct TraktShowProgress: Decodable, Sendable {
    struct Season: Decodable, Sendable {
        struct Episode: Decodable, Sendable {
            let number: Int
            let completed: Bool
            let lastWatchedAt: Date?
        }
        let number: Int
        let episodes: [Episode]
    }
    let seasons: [Season]

    /// Only the watched episodes, in the shape the snapshot reads.
    var watchedSeasons: [TraktWatchedShow.Season] {
        seasons.compactMap { season in
            let watched = season.episodes.filter(\.completed)
                .map { TraktWatchedShow.Season.Episode(number: $0.number, lastWatchedAt: $0.lastWatchedAt) }
            return watched.isEmpty ? nil : TraktWatchedShow.Season(number: season.number, episodes: watched)
        }
    }
}

/// `/sync/history` answers with what it took and what it could not match.
nonisolated struct TraktHistoryResult: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        let movies: Int?
        let episodes: Int?
    }
    struct NotFound: Decodable, Sendable {
        let movies: [TraktMovie]?
        let shows: [TraktShow]?
        let episodes: [TraktEpisode]?
    }
    let added: Counts?
    let notFound: NotFound?
}

nonisolated struct TraktRatedItem: Decodable, Sendable {
    let rating: Int
    let movie: TraktMovie?
    let show: TraktShow?
}

/// One entry of the watchlist or a personal list. Only movies and shows are kept: a season or an
/// episode on a list has no card of its own in Sodalite.
nonisolated struct TraktListEntry: Decodable, Sendable {
    let rank: Int?
    let type: String
    let movie: TraktMovie?
    let show: TraktShow?
}

nonisolated struct TraktList: Decodable, Sendable {
    let name: String
    let itemCount: Int?
    let ids: TraktIDs
}

// MARK: - Write bodies

/// `/sync/history`, `/sync/ratings`, `/sync/watchlist` and their `/remove` twins all take this shape.
nonisolated struct TraktSyncBody: Encodable, Sendable, Equatable {
    struct Movie: Encodable, Sendable, Equatable {
        let ids: TraktIDs
        /// An ISO date or "unknown" (`TraktDate.wire`). Never left out on an add: Trakt then
        /// stamps the play with the current time, and it does not de-duplicate plays.
        var watchedAt: String?
        var rating: Int?
        enum CodingKeys: String, CodingKey { case ids, watchedAt = "watched_at", rating }
    }
    struct Show: Encodable, Sendable, Equatable {
        struct Season: Encodable, Sendable, Equatable {
            struct Episode: Encodable, Sendable, Equatable {
                let number: Int
                var watchedAt: String?
                enum CodingKeys: String, CodingKey { case number, watchedAt = "watched_at" }
            }
            let number: Int
            /// nil addresses the whole season (a removal does that).
            var episodes: [Episode]?
        }
        let ids: TraktIDs
        var seasons: [Season]?
        var rating: Int?
    }
    struct Episode: Encodable, Sendable, Equatable {
        let ids: TraktIDs
        var rating: Int?
    }
    var movies: [Movie] = []
    var shows: [Show] = []
    var episodes: [Episode] = []

    var isEmpty: Bool { movies.isEmpty && shows.isEmpty && episodes.isEmpty }
}

nonisolated struct TraktScrobbleBody: Encodable, Sendable {
    struct Episode: Encodable, Sendable {
        var season: Int?
        var number: Int?
        var ids: TraktIDs?
    }
    var movie: TraktMovie?
    var show: TraktShow?
    var episode: Episode?
    let progress: Double
}

nonisolated struct TraktDeviceCodeRequest: Encodable, Sendable {
    let clientID: String
    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
}

nonisolated struct TraktDeviceTokenRequest: Encodable, Sendable {
    let code: String
    let clientID: String
    enum CodingKeys: String, CodingKey { case code, clientID = "client_id" }
}

nonisolated struct TraktRefreshRequest: Encodable, Sendable {
    let refreshToken: String
    let clientID: String
    let redirectURI: String
    let grantType = "refresh_token"
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token", clientID = "client_id"
        case redirectURI = "redirect_uri", grantType = "grant_type"
    }
}

nonisolated struct TraktRevokeRequest: Encodable, Sendable {
    let token: String
    let clientID: String
    enum CodingKeys: String, CodingKey { case token, clientID = "client_id" }
}

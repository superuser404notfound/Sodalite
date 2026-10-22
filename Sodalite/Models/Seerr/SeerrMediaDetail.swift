import Foundation

struct SeerrMovieDetail: Codable, Sendable {
    let id: Int
    let title: String
    let originalTitle: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let mediaInfo: SeerrMediaInfo?
    let credits: SeerrCredits?
    let watchProviders: [SeerrWatchProviderRegion]?
    let releases: SeerrReleases?
    let externalIds: SeerrExternalIds?
    /// TMDB's `belongs_to_collection`, present only for movies that are part of one; drives the collection entry point.
    let collection: SeerrCollectionRef?

    var displayYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    func certification(region: String) -> String? {
        seerrCertification(movieReleases: releases, region: region)
    }
}

struct SeerrTVDetail: Codable, Sendable {
    let id: Int
    let name: String
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let numberOfSeasons: Int?
    let seasons: [SeerrSeason]?
    let mediaInfo: SeerrMediaInfo?
    let credits: SeerrCredits?
    let watchProviders: [SeerrWatchProviderRegion]?
    let contentRatings: SeerrContentRatings?
    let externalIds: SeerrExternalIds?
    /// TMDB's next scheduled episode, nil once a show has nothing announced. Feeds the Upcoming row
    /// for series whose Jellyfin library lists no future episode (Sodalite#198).
    let nextEpisodeToAir: SeerrEpisode?

    var displayYear: String? {
        guard let firstAirDate, firstAirDate.count >= 4 else { return nil }
        return String(firstAirDate.prefix(4))
    }

    func certification(region: String) -> String? {
        seerrCertification(tvRatings: contentRatings, region: region)
    }
}

/// External provider ids from `/movie|tv/{id}` (TMDB-shaped `external_ids`). Used to match a Seerr title against the Jellyfin library: Sonarr-pipeline series often carry only a Tvdb id in Jellyfin and lack a Tmdb id, so tvdbId/imdbId are required fallbacks for a reliable presence check.
struct SeerrExternalIds: Codable, Sendable, Equatable {
    let tvdbId: Int?
    let imdbId: String?
}

struct SeerrSeason: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let overview: String?
    let episodeCount: Int?
    let airDate: String?
    let posterPath: String?
}

struct SeerrGenre: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
}

/// Per-season detail from `/tv/{id}/season/{n}` for the read-only episode list; informational only (requests still take whole seasons).
struct SeerrSeasonDetail: Codable, Sendable, Equatable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let overview: String?
    let airDate: String?
    let episodes: [SeerrEpisode]?
}

struct SeerrEpisode: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let episodeNumber: Int
    let seasonNumber: Int?
    let name: String?
    let overview: String?
    let stillPath: String?
    let airDate: String?
    let voteAverage: Double?
    let runtime: Int?
}

// MARK: - Credits

struct SeerrCastMember: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?
}

struct SeerrCredits: Codable, Sendable, Equatable {
    let cast: [SeerrCastMember]?
}

// MARK: - Watch Providers

struct SeerrWatchProvider: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let logoPath: String?
}

struct SeerrWatchProviderRegion: Codable, Sendable, Equatable {
    let iso31661: String
    let link: String?
    let flatrate: [SeerrWatchProvider]?
    let buy: [SeerrWatchProvider]?
    let rent: [SeerrWatchProvider]?
}

// MARK: - Certification

struct SeerrReleases: Codable, Sendable, Equatable {
    struct RegionReleases: Codable, Sendable, Equatable {
        let iso31661: String
        let releaseDates: [ReleaseDate]?
    }
    struct ReleaseDate: Codable, Sendable, Equatable {
        let certification: String?
    }
    let results: [RegionReleases]?
}

/// Rotten Tomatoes rating from `/movie/{id}/ratings` (or `/tv/...`); `criticsScore` is the Tomatometer (0-100), fresh/rotten splits at 60 (matches Jellyfin badge). The endpoint also returns criticsRating/audienceScore/audienceRating/url, which are intentionally not decoded since only the Tomatometer is surfaced.
struct SeerrRTRating: Codable, Sendable, Equatable {
    let criticsScore: Int?
}

struct SeerrContentRatings: Codable, Sendable, Equatable {
    struct RegionRating: Codable, Sendable, Equatable {
        let iso31661: String
        let rating: String?
    }
    let results: [RegionRating]?
}

func seerrCertification(movieReleases: SeerrReleases?, region: String) -> String? {
    guard let results = movieReleases?.results else { return nil }
    let pick = results.first { $0.iso31661 == region }
        ?? results.first { $0.iso31661 == "US" }
    return pick?.releaseDates?
        .compactMap { $0.certification }
        .first { !$0.isEmpty }
}

func seerrCertification(tvRatings: SeerrContentRatings?, region: String) -> String? {
    guard let results = tvRatings?.results else { return nil }
    let pick = results.first { $0.iso31661 == region }
        ?? results.first { $0.iso31661 == "US" }
    return pick?.rating.flatMap { $0.isEmpty ? nil : $0 }
}

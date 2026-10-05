import Foundation

enum SeerrEndpoint: APIEndpoint {
    case status
    case authJellyfin(body: SeerrJellyfinAuthBody)
    case authMe
    case authLogout

    case discoverTrending(page: Int)
    case discoverMovies(page: Int)
    case discoverTV(page: Int)
    case discoverUpcomingMovies(page: Int)
    case discoverUpcomingTV(page: Int)
    case discoverMoviesByGenre(genreID: Int, page: Int)
    case discoverTVByGenre(genreID: Int, page: Int)
    case discoverMoviesByStudio(studioID: Int, page: Int)
    case discoverTVByNetwork(networkID: Int, page: Int)
    case genresMovie
    case genresTV

    case search(query: String, page: Int)

    case movieDetail(tmdbID: Int)
    case tvDetail(tmdbID: Int)
    /// GET /api/v1/collection/{id}: a TMDB movie collection plus its parts, each with the same mediaInfo the discover rows carry.
    case collection(collectionID: Int)
    case tvSeasonDetail(tmdbID: Int, seasonNumber: Int)
    case personDetail(tmdbID: Int)
    case personCombinedCredits(tmdbID: Int)
    case movieRecommendations(tmdbID: Int, page: Int)
    case movieSimilar(tmdbID: Int, page: Int)
    case tvRecommendations(tmdbID: Int, page: Int)
    case tvSimilar(tmdbID: Int, page: Int)
    /// GET /api/v1/movie|tv/{id}/ratings: Rotten Tomatoes scores.
    case movieRatings(tmdbID: Int)
    case tvRatings(tmdbID: Int)
    case discoverMoviesByWatchProvider(providerID: Int, region: String, page: Int)
    case discoverTVByWatchProvider(providerID: Int, region: String, page: Int)

    case createRequest(body: SeerrCreateRequestBody)
    case myRequests(userID: Int, take: Int, skip: Int, sort: SeerrRequestSort)

    /// GET /api/v1/request, all users' requests; needs MANAGE_REQUESTS or ADMIN.
    case allRequests(filter: SeerrRequestFilter, take: Int, skip: Int)
    /// POST approve: pending → approved, sends to Radarr/Sonarr; 403 without MANAGE_REQUESTS.
    case approveRequest(requestID: Int)
    /// POST decline: pending → declined; same response shape as approve.
    case declineRequest(requestID: Int)
    /// DELETE the request entry; does not delete an already-downloaded file.
    case deleteRequest(requestID: Int)
    /// PUT to modify server/profile/root-folder/seasons; partial body, only changed fields.
    case updateRequest(requestID: Int, body: SeerrRequestUpdateBody)

    case radarrServers
    case radarrDetails(serverID: Int)
    case sonarrServers
    case sonarrDetails(serverID: Int)

    /// DELETE media/file: proxies to Radarr removeMovie / Sonarr removeSeries (deleteFiles:true). Jellyfin already removed the file, so the *arr file-delete is a no-op; we want the DB-entry removal. Needs MANAGE_REQUESTS.
    case mediaFileDelete(seerrMediaID: Int)

    var path: String {
        switch self {
        case .status: "/api/v1/status"
        case .authJellyfin: "/api/v1/auth/jellyfin"
        case .authMe: "/api/v1/auth/me"
        case .authLogout: "/api/v1/auth/logout"
        case .discoverTrending: "/api/v1/discover/trending"
        case .discoverMovies: "/api/v1/discover/movies"
        case .discoverTV: "/api/v1/discover/tv"
        case .discoverUpcomingMovies: "/api/v1/discover/movies/upcoming"
        case .discoverUpcomingTV: "/api/v1/discover/tv/upcoming"
        case .discoverMoviesByGenre(let genreID, _): "/api/v1/discover/movies/genre/\(genreID)"
        case .discoverTVByGenre(let genreID, _): "/api/v1/discover/tv/genre/\(genreID)"
        case .discoverMoviesByStudio(let studioID, _): "/api/v1/discover/movies/studio/\(studioID)"
        case .discoverTVByNetwork(let networkID, _): "/api/v1/discover/tv/network/\(networkID)"
        case .genresMovie: "/api/v1/discover/genreslider/movie"
        case .genresTV: "/api/v1/discover/genreslider/tv"
        case .search: "/api/v1/search"
        case .movieDetail(let id): "/api/v1/movie/\(id)"
        case .tvDetail(let id): "/api/v1/tv/\(id)"
        case .collection(let id): "/api/v1/collection/\(id)"
        case .tvSeasonDetail(let id, let n): "/api/v1/tv/\(id)/season/\(n)"
        case .personDetail(let id): "/api/v1/person/\(id)"
        case .personCombinedCredits(let id): "/api/v1/person/\(id)/combined_credits"
        case .movieRecommendations(let id, _): "/api/v1/movie/\(id)/recommendations"
        case .movieSimilar(let id, _): "/api/v1/movie/\(id)/similar"
        case .tvRecommendations(let id, _): "/api/v1/tv/\(id)/recommendations"
        case .tvSimilar(let id, _): "/api/v1/tv/\(id)/similar"
        case .movieRatings(let id): "/api/v1/movie/\(id)/ratings"
        case .tvRatings(let id): "/api/v1/tv/\(id)/ratings"
        case .discoverMoviesByWatchProvider: "/api/v1/discover/movies"
        case .discoverTVByWatchProvider: "/api/v1/discover/tv"
        case .createRequest: "/api/v1/request"
        case .myRequests: "/api/v1/request"
        case .allRequests: "/api/v1/request"
        case .approveRequest(let id): "/api/v1/request/\(id)/approve"
        case .declineRequest(let id): "/api/v1/request/\(id)/decline"
        case .deleteRequest(let id): "/api/v1/request/\(id)"
        case .updateRequest(let id, _): "/api/v1/request/\(id)"
        case .radarrServers: "/api/v1/service/radarr"
        case .radarrDetails(let id): "/api/v1/service/radarr/\(id)"
        case .sonarrServers: "/api/v1/service/sonarr"
        case .sonarrDetails(let id): "/api/v1/service/sonarr/\(id)"
        case .mediaFileDelete(let id): "/api/v1/media/\(id)/file"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .authJellyfin, .createRequest: .post
        case .authLogout: .post
        case .mediaFileDelete, .deleteRequest: .delete
        case .approveRequest, .declineRequest: .post
        case .updateRequest: .put
        default: .get
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .discoverTrending(let page),
             .discoverMovies(let page),
             .discoverTV(let page),
             .discoverUpcomingMovies(let page),
             .discoverUpcomingTV(let page):
            return [URLQueryItem(name: "page", value: String(page))]

        case .discoverMoviesByGenre(_, let page),
             .discoverTVByGenre(_, let page),
             .discoverMoviesByStudio(_, let page),
             .discoverTVByNetwork(_, let page):
            return [URLQueryItem(name: "page", value: String(page))]

        case .discoverMoviesByWatchProvider(let providerID, let region, let page),
             .discoverTVByWatchProvider(let providerID, let region, let page):
            return [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "watchProviders", value: String(providerID)),
                URLQueryItem(name: "watchRegion", value: region),
            ]

        case .search(let query, let page):
            return [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(page)),
            ]

        case .myRequests(let userID, let take, let skip, let sort):
            return [
                URLQueryItem(name: "take", value: String(take)),
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "filter", value: "all"),
                URLQueryItem(name: "sort", value: sort.rawValue),
                // requestedBy takes an integer user ID; "me" silently matched zero requests.
                URLQueryItem(name: "requestedBy", value: String(userID)),
            ]

        case .allRequests(let filter, let take, let skip):
            return [
                URLQueryItem(name: "take", value: String(take)),
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "filter", value: filter.rawValue),
                URLQueryItem(name: "sort", value: "added"),
            ]

        case .movieRecommendations(_, let page),
             .movieSimilar(_, let page),
             .tvRecommendations(_, let page),
             .tvSimilar(_, let page):
            return [URLQueryItem(name: "page", value: String(page))]

        case .mediaFileDelete:
            // is4k is required by the endpoint; Sodalite has no 4K-profile distinction, always false.
            return [URLQueryItem(name: "is4k", value: "false")]

        default:
            return nil
        }
    }

    var body: (any Encodable & Sendable)? {
        switch self {
        case .authJellyfin(let body): body
        case .createRequest(let body): body
        case .updateRequest(_, let body): body
        default: nil
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .status, .authJellyfin: false
        default: true
        }
    }
}

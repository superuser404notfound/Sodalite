import Foundation

nonisolated enum TraktHost {
    /// Every OAuth call: device codes, token, refresh, revoke. Trakt enforces this host for sign-in
    /// from 2027-02-01; the API host stops signing users in then.
    static let auth = URL(string: "https://auth.trakt.tv")!
    static let api = URL(string: "https://api.trakt.tv")!
    /// What the user opens on a phone to type the device code. The QR code carries the code too.
    static let activate = "https://auth.trakt.tv/activate"
    /// The device flow never redirects, but a refresh still has to name the URI the app registered.
    static let outOfBandRedirect = "urn:ietf:wg:oauth:2.0:oob"
}

enum TraktEndpoint: APIEndpoint {
    case deviceCode(TraktDeviceCodeRequest)
    case deviceToken(TraktDeviceTokenRequest)
    case refresh(TraktRefreshRequest)
    case revoke(TraktRevokeRequest)

    case userSettings
    case lastActivities
    case watchedMovies
    case watchedShows
    case showProgress(traktID: Int)
    case addHistory(TraktSyncBody)
    case removeHistory(TraktSyncBody)
    case ratings(type: String)
    case addRatings(TraktSyncBody)
    case removeRatings(TraktSyncBody)
    case watchlist
    case addToWatchlist(TraktSyncBody)
    case removeFromWatchlist(TraktSyncBody)
    case lists
    case listItems(listID: Int)
    case scrobble(action: ScrobbleAction, body: TraktScrobbleBody)

    enum ScrobbleAction: String, Sendable { case start, pause, stop }

    var isAuth: Bool {
        switch self {
        case .deviceCode, .deviceToken, .refresh, .revoke: true
        default: false
        }
    }

    var path: String {
        switch self {
        case .deviceCode: "/oauth/device/code"
        case .deviceToken: "/oauth/device/token"
        case .refresh: "/oauth/token"
        case .revoke: "/oauth/revoke"
        case .userSettings: "/users/settings"
        case .lastActivities: "/sync/last_activities"
        // The /users route, not /sync/watched: the sync one is untyped in Trakt's contract and came
        // back without `seasons` on the first device test (0 episode keys for a history of
        // hundreds), so every watched episode looked unwatched and was pushed again each sync.
        case .watchedMovies: "/users/me/watched/movies"
        case .watchedShows: "/users/me/watched/shows"
        case .showProgress(let id): "/shows/\(id)/progress/watched"
        case .addHistory: "/sync/history"
        case .removeHistory: "/sync/history/remove"
        case .ratings(let type): "/sync/ratings/\(type)"
        case .addRatings: "/sync/ratings"
        case .removeRatings: "/sync/ratings/remove"
        case .watchlist: "/sync/watchlist/movie,show/rank/asc"
        case .addToWatchlist: "/sync/watchlist"
        case .removeFromWatchlist: "/sync/watchlist/remove"
        case .lists: "/users/me/lists"
        case .listItems(let listID): "/users/me/lists/\(listID)/items/movie,show"
        case .scrobble(let action, _): "/scrobble/\(action.rawValue)"
        }
    }

    /// The comma in the watchlist and list item paths is a literal Trakt expects, and
    /// `appendingPathComponent` would leave it alone anyway; the paths carry no user input.
    var percentEncodedPath: String? {
        switch self {
        case .watchlist, .listItems: path
        default: nil
        }
    }

    var method: HTTPMethod {
        switch self {
        case .userSettings, .lastActivities, .watchedMovies, .watchedShows, .showProgress,
             .ratings, .watchlist,
             .lists, .listItems:
            .get
        default:
            .post
        }
    }

    var body: (any Encodable & Sendable)? {
        switch self {
        case .deviceCode(let body): body
        case .deviceToken(let body): body
        case .refresh(let body): body
        case .revoke(let body): body
        case .addHistory(let body), .removeHistory(let body), .addRatings(let body), .removeRatings(let body),
             .addToWatchlist(let body), .removeFromWatchlist(let body):
            body
        case .scrobble(_, let body): body
        default: nil
        }
    }

    /// `extended=full` is what carries the poster on list entries.
    var queryItems: [URLQueryItem]? {
        switch self {
        case .watchlist, .listItems: [URLQueryItem(name: "extended", value: "full")]
        // Specials and hidden seasons in, so season 0 and hidden seasons match what Jellyfin holds.
        case .showProgress:
            [URLQueryItem(name: "specials", value: "true"), URLQueryItem(name: "count_specials", value: "false"),
             URLQueryItem(name: "hidden", value: "true")]
        default: nil
        }
    }

    var requiresAuth: Bool { !isAuth }

    var isWrite: Bool { method != .get && !isAuth }
}

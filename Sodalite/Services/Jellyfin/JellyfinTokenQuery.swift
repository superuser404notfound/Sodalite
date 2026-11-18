import Foundation

/// The one spelling of the access token in a URL that is fetched without our headers (audit NET-R203).
/// Both names go out: `api_key` is what servers before 10.9 read (the theme song omitted it and got a
/// 401 there), `ApiKey` is what current servers read, and Jellyfin 12 ignores `api_key` on some routes.
nonisolated enum JellyfinTokenQuery {
    static func items(_ token: String) -> [URLQueryItem] {
        [URLQueryItem(name: "api_key", value: token), URLQueryItem(name: "ApiKey", value: token)]
    }

    /// `api_key=...&ApiKey=...` for URLs that are assembled by hand.
    static func queryString(_ token: String) -> String {
        items(token).map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }
}

import Foundation

/// Sodalite#219: the theme song a detail page plays, from the server's own theme media (a `theme.mp3`
/// next to the item, or what a plugin such as Themerr put there).
@MainActor
protocol JellyfinThemeSongServiceProtocol {
    /// The item's first theme song (inherited from the series for a season or episode), or nil.
    func themeSong(userID: String, itemID: String) async throws -> ThemeSongTarget?
}

@MainActor
final class JellyfinThemeSongService: JellyfinThemeSongServiceProtocol {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func themeSong(userID: String, itemID: String) async throws -> ThemeSongTarget? {
        let response = try await client.request(
            endpoint: JellyfinEndpoint.themeSongs(userID: userID, itemID: itemID),
            responseType: JellyfinItemsResponse.self
        )
        guard let song = response.items.first,
              let url = Self.streamURL(songID: song.id, userID: userID, client: client) else { return nil }
        return ThemeSongTarget(songID: song.id, url: url)
    }

    /// The universal route serves a file AVPlayer can open as it is and transcodes the rest (Ogg, Opus,
    /// WMA) to AAC over HLS, so the song plays whatever format the plugin downloaded.
    static func streamURL(songID: String, userID: String, client: JellyfinClient) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Audio/\(songID)/universal"), resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "DeviceId", value: client.deviceID),
            URLQueryItem(name: "Container", value: "mp3,aac,m4a|aac,m4b|aac,flac,alac,m4a|alac,wav"),
            URLQueryItem(name: "TranscodingContainer", value: "mp4"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "320000"),
            // Not `api_key`: Jellyfin 12 answers that one with 401 on this route (the static stream route
            // still takes it). `ApiKey` is the current name and older servers read it too.
            URLQueryItem(name: "ApiKey", value: token),
        ]
        return components?.url
    }
}

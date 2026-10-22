import Foundation

/// One entry of Jellyfin's `RemoteTrailers` (requires RemoteTrailers in Fields), filled from TMDB and
/// in practice almost always a YouTube watch URL (Sodalite#195).
struct RemoteTrailer: Codable, Sendable, Hashable {
    let url: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case url = "Url"
        case name = "Name"
    }

    /// The YouTube video id this URL points at, nil for anything else. Covers the shapes TMDB and
    /// hand-edited metadata produce: watch?v=, youtu.be/, /embed/, /shorts/, /live/, /v/, and the
    /// nocookie and mobile hosts.
    var youTubeVideoID: String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: raw.contains("://") ? raw : "https://\(raw)"),
              let host = components.host?.lowercased()
        else { return nil }

        let segments = components.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" {
            candidate = segments.first
        } else if Self.youTubeHosts.contains(host) {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
                candidate = v
            } else if segments.count >= 2, ["embed", "shorts", "live", "v"].contains(segments[0]) {
                candidate = segments[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let id = candidate, Self.isVideoID(id) else { return nil }
        return id
    }

    private static let youTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    /// YouTube ids are 11 characters of the URL-safe base64 alphabet. Checking that keeps a stray
    /// value out of the embed page, which interpolates it.
    private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// A remote trailer the detail page opens in YouTube's own embedded player (Sodalite#195).
struct YouTubeTrailer: Identifiable, Hashable {
    let videoID: String
    let title: String?
    var id: String { videoID }

    var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    /// The 1280x720 still, which older or low-resolution uploads lack.
    var thumbnailURL: URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg")!
    }

    /// 320x180, generated for every video, and 16:9 like the card (the larger `hqdefault` is 4:3 with bars).
    var fallbackThumbnailURL: URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")!
    }
}

extension JellyfinItem {
    /// The remote trailers that resolve to a YouTube video, the only kind the embed can play, in the
    /// server's order and without repeats (TMDB lists the same video under several languages).
    var youTubeTrailers: [YouTubeTrailer] {
        var seen = Set<String>()
        return (remoteTrailers ?? []).compactMap { trailer in
            guard let id = trailer.youTubeVideoID, seen.insert(id).inserted else { return nil }
            return YouTubeTrailer(videoID: id, title: trailer.name)
        }
    }
}

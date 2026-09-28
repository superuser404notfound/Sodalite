import Foundation

/// `EpisodeCatalogQuerying` (getSeasons / getEpisodes) is inherited: the replaced-item lookup needs those
/// two and nothing else, and a narrow face keeps it testable without the twenty methods below.
protocol JellyfinPlaybackServiceProtocol: EpisodeCatalogQuerying {
    var baseURL: URL? { get }
    /// Stable per-install device id, the one the auth header and the stream URLs carry. Exposed
    /// because the tuner sweep has to tell our own session apart from every other client's (#147).
    var deviceID: String { get }
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?) async throws -> PlaybackInfoResponse
    /// Same request pinned to one media source, naming the audio stream a transcode should carry.
    /// Jellyfin applies a stream index only to the source the request names, and then answers with
    /// that source alone (Sodalite#87).
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?,
                         mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse
    /// Live PlaybackInfo: AutoOpenLiveStream probes the stream (known codecs → DirectStream/copy, real LiveStreamId for tuner release); maxStreamingBitrate caps a transcode.
    ///
    /// `enableDirectPlay` is true for every ordinary tune and false only on the second pass a channel
    /// with undecodable audio takes (#100). Jellyfin answers a DirectPlay verdict with neither a
    /// TranscodingUrl nor a reason, so taking that verdict off the table is the only way to see what
    /// else the server would have offered.
    func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]?, maxStreamingBitrate: Int, enableDirectPlay: Bool) async throws -> PlaybackInfoResponse
    func reportPlaybackStart(_ report: PlaybackStartReport) async throws
    func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws
    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws
    func closeLiveStream(liveStreamID: String) async throws
    func stopActiveEncodings(playSessionID: String) async throws
    /// Who the server thinks is playing what. The tuner sweep reads it before closing a leftover
    /// handle, because that handle names the CHANNEL and could belong to another client by now (#147).
    func getSessions() async throws -> [JellyfinSessionInfo]
    func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments
    func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL?
    func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL?
    func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL?
    /// Server-rendered chapter image (from the "Chapter image extraction" task); `chapterIndex` indexes the original `Chapters` array. Nil without server/token, caller decodes a still itself.
    func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL?
    /// Server-generated trickplay tile sprite (Jellyfin 10.9+ Trickplay task); a grid of thumbnails at the given rendition `width`. Nil without server/token. Present only when the server generated tiles.
    func buildTrickplayTileURL(itemID: String, width: Int, tileIndex: Int) -> URL?
    /// Searches server subtitle provider(s); `language` is 3-letter ISO 639-2. Empty = no results, throws on missing provider plugin (404/500).
    func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo]
    /// Server downloads `subtitleID` and attaches it to `itemID` as an external stream.
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws
    /// Deletes external subtitle at `index`; needs subtitle-management rights.
    func deleteSubtitle(itemID: String, index: Int) async throws
    func buildTranscodeURL(relativePath: String) -> URL?
    func buildLiveStreamFileURL(sourcePath: String) -> URL?
}

extension JellyfinPlaybackServiceProtocol {
    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?,
                         mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse {
        try await getPlaybackInfo(itemID: itemID, userID: userID, profile: profile)
    }
}

final class JellyfinPlaybackService: JellyfinPlaybackServiceProtocol {
    let client: JellyfinClient

    var baseURL: URL? { client.baseURL }

    var deviceID: String { client.deviceID }

    init(client: JellyfinClient) {
        self.client = client
    }

    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]? = nil) async throws -> PlaybackInfoResponse {
        try await getPlaybackInfo(itemID: itemID, userID: userID, profile: profile,
                                  mediaSourceID: nil, audioStreamIndex: nil)
    }

    func getPlaybackInfo(itemID: String, userID: String, profile: [String: Any]?,
                         mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse {
        let body = Self.vodPlaybackInfoBody(profile: profile ?? [:], mediaSourceID: mediaSourceID,
                                            audioStreamIndex: audioStreamIndex)
        return try await postPlaybackInfo(profile: profile, body: body) { payload in
            JellyfinEndpoint.playbackInfo(itemID: itemID, userID: userID, payload: payload)
        }
    }

    /// The VOD body: the rung travels as the top-level `MaxStreamingBitrate` too (Sodalite#87), and
    /// `SubtitleStreamIndex` is -1, "none". Sodalite draws every subtitle itself; a stream the server
    /// picked would be burned into a transcode, which Jellyfin prepares by extracting every subtitle
    /// from the whole file first (a minute on a 15 GB remux, measured 2026-09-28), and would then
    /// show twice. Both indexes count only with `MediaSourceId` set, and only a source id the server
    /// gave out may go there: one that matches no source makes it answer with no source at all.
    static func vodPlaybackInfoBody(profile: [String: Any], mediaSourceID: String?,
                                    audioStreamIndex: Int?) -> [String: Any] {
        var body = playbackInfoBody(profile: profile,
                                    maxStreamingBitrate: profile["MaxStreamingBitrate"] as? Int,
                                    audioStreamIndex: audioStreamIndex, enableDirectPlay: true)
        body["SubtitleStreamIndex"] = -1
        if let mediaSourceID { body["MediaSourceId"] = mediaSourceID }
        return body
    }

    func getLivePlaybackInfo(itemID: String, userID: String, profile: [String: Any]? = nil, maxStreamingBitrate: Int, enableDirectPlay: Bool = true) async throws -> PlaybackInfoResponse {
        let body = Self.playbackInfoBody(profile: profile ?? [:], maxStreamingBitrate: nil,
                                         enableDirectPlay: enableDirectPlay)
        return try await postPlaybackInfo(profile: profile, body: body) { payload in
            JellyfinEndpoint.livePlaybackInfo(
                itemID: itemID,
                userID: userID,
                maxStreamingBitrate: maxStreamingBitrate,
                payload: payload
            )
        }
    }

    /// The PlaybackInfo body. For VOD the rung also travels as the top-level `MaxStreamingBitrate`,
    /// the PlaybackInfoDto field (Sodalite#87). Live passes nil: it sends its cap as a query item, and
    /// a second value in the body could contradict the 12 Mbit/s re-encode pass.
    ///
    /// `EnableDirectPlay` is sent only when it is false. The field defaults to true on every Jellyfin
    /// that has it, and a body that names it on every request would carry a flag most servers never
    /// needed to read.
    static func playbackInfoBody(profile: [String: Any], maxStreamingBitrate: Int?,
                                 audioStreamIndex: Int? = nil,
                                 enableDirectPlay: Bool) -> [String: Any] {
        var body: [String: Any] = ["DeviceProfile": profile]
        if let maxStreamingBitrate { body["MaxStreamingBitrate"] = maxStreamingBitrate }
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }
        if !enableDirectPlay { body["EnableDirectPlay"] = false }
        return body
    }

    /// Routes through the shared HTTPClient (limiter, timeouts, APIError, cookie-free) not URLSession.shared; uses requestData + manual decode because DEBUG codec diagnostics need raw data.
    private func postPlaybackInfo(
        profile: [String: Any]?,
        body: [String: Any],
        endpoint: (JSONValue) throws -> JellyfinEndpoint
    ) async throws -> PlaybackInfoResponse {
        guard let baseURL = client.baseURL else { throw APIError.invalidURL }

        // Caller picks the profile (DirectPlayProfile.current() touches UIScreen, must run on the main actor); empty fallback shouldn't happen in practice.
        let deviceProfile = profile ?? [:]

        #if DEBUG
        if let dp = (deviceProfile["DirectPlayProfiles"] as? [[String: Any]])?.first {
            print("[PlaybackInfo] DirectPlay containers: \(dp["Container"] ?? "none")")
        }
        #endif

        let payload = try JSONValue(jsonObject: body)
        let headers = [
            "Authorization": client.buildAuthHeader(),
            "Accept": "application/json",
        ]
        let (data, _) = try await client.httpClient.requestData(
            baseURL: baseURL,
            endpoint: try endpoint(payload),
            headers: headers
        )

        #if DEBUG
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sources = json["MediaSources"] as? [[String: Any]],
           let first = sources.first {
            print("[PlaybackInfo] Response container=\(first["Container"] ?? "nil"), directPlay=\(first["SupportsDirectPlay"] ?? "nil"), directStream=\(first["SupportsDirectStream"] ?? "nil")")
            if let reason = first["TranscodingUrl"] as? String, reason.contains("TranscodeReasons") {
                if let range = reason.range(of: "TranscodeReasons=") {
                    let reasons = reason[range.upperBound...]
                    print("[PlaybackInfo] TranscodeReasons: \(reasons.prefix(100))")
                }
            }
            // Source codec per stream: names the exact codec behind a live VideoCodecNotSupported so the copy list / FFmpegBuild decoder set extends deliberately.
            if let streams = first["MediaStreams"] as? [[String: Any]] {
                let desc = streams.map { s in
                    "\(s["Type"] ?? "?")=\(s["Codec"] ?? "?")\(s["Profile"].map { "(\($0))" } ?? "")"
                }.joined(separator: " ")
                print("[PlaybackInfo] Source streams: \(desc)")
            }
        }
        #endif

        do {
            return try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func reportPlaybackStart(_ report: PlaybackStartReport) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.sessionPlaying(report: report)
        )
    }

    func reportPlaybackProgress(_ report: PlaybackProgressReport) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.sessionProgress(report: report)
        )
    }

    func reportPlaybackStopped(_ report: PlaybackStopReport) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.sessionStopped(report: report)
        )
    }

    func closeLiveStream(liveStreamID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.closeLiveStream(liveStreamID: liveStreamID)
        )
    }

    func getSessions() async throws -> [JellyfinSessionInfo] {
        try await client.request(
            endpoint: JellyfinEndpoint.sessions,
            responseType: [JellyfinSessionInfo].self
        )
    }

    /// Kill the transcode + its output for this device/play-session. A lost stop report otherwise keeps ffmpeg growing stream.ts until the disk fills, so every teardown fires this.
    func stopActiveEncodings(playSessionID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.stopActiveEncodings(
                deviceID: client.deviceID, playSessionID: playSessionID)
        )
    }

    func getSeasons(seriesID: String, userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.seasons(seriesID: seriesID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    func getEpisodes(seriesID: String, seasonID: String, userID: String) async throws -> [JellyfinItem] {
        let response: JellyfinItemsResponse = try await client.request(
            endpoint: JellyfinEndpoint.episodes(seriesID: seriesID, seasonID: seasonID, userID: userID),
            responseType: JellyfinItemsResponse.self
        )
        return response.items
    }

    /// Intro + outro + recap markers in one call; empty struct on 404 (pre-10.10 without intro-skipper) or no segments.
    func getEpisodeSegments(itemID: String) async throws -> EpisodeSegments {
        do {
            let response: MediaSegmentsResponse = try await client.request(
                endpoint: JellyfinEndpoint.mediaSegments(itemID: itemID),
                responseType: MediaSegmentsResponse.self
            )
            return EpisodeSegments(
                intro: response.items.first(where: { $0.type == .intro }),
                outro: response.items.first(where: { $0.type == .outro }),
                recap: response.items.first(where: { $0.type == .recap })
            )
        } catch APIError.httpError(let status, _) where status == 404 {
            return EpisodeSegments(intro: nil, outro: nil, recap: nil)
        }
    }

    func searchRemoteSubtitles(itemID: String, language: String) async throws -> [RemoteSubtitleInfo] {
        try await client.request(
            endpoint: JellyfinEndpoint.remoteSearchSubtitles(itemID: itemID, language: language),
            responseType: [RemoteSubtitleInfo].self
        )
    }

    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.downloadRemoteSubtitle(itemID: itemID, subtitleID: subtitleID)
        )
    }

    func deleteSubtitle(itemID: String, index: Int) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.deleteSubtitle(itemID: itemID, index: index)
        )
    }

    func buildStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? {
        buildMediaStreamURL(pathPrefix: "Videos", itemID: itemID, mediaSourceID: mediaSourceID, container: container, defaultExt: "mp4", isStatic: isStatic)
    }

    func buildAudioStreamURL(itemID: String, mediaSourceID: String, container: String?, isStatic: Bool) -> URL? {
        buildMediaStreamURL(pathPrefix: "Audio", itemID: itemID, mediaSourceID: mediaSourceID, container: container, defaultExt: "mp3", isStatic: isStatic)
    }

    private func buildMediaStreamURL(pathPrefix: String, itemID: String, mediaSourceID: String, container: String?, defaultExt: String, isStatic: Bool) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let ext = container ?? defaultExt
        var components = URLComponents(url: baseURL.appendingPathComponent("/\(pathPrefix)/\(itemID)/stream.\(ext)"), resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "MediaSourceId", value: mediaSourceID),
            URLQueryItem(name: "api_key", value: token),
        ]
        if isStatic {
            queryItems.append(URLQueryItem(name: "Static", value: "true"))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    func buildSubtitleURL(itemID: String, mediaSourceID: String, streamIndex: Int, format: String) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let fmt = Self.subtitleRouteFormat(forCodec: format)
        let path = "/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/0/Stream.\(fmt)"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "api_key", value: token)]
        return components?.url
    }

    /// The subtitle route's trailing token is the file extension Jellyfin serves, not the codec
    /// name ffprobe reports. Two of those names differ, and asking for one Jellyfin has no writer
    /// for loses the track: `subrip` is served as `.srt`, `webvtt` as `.vtt`.
    static func subtitleRouteFormat(forCodec codec: String) -> String {
        switch codec.lowercased() {
        case "subrip": return "srt"
        case "webvtt": return "vtt"
        default: return codec
        }
    }

    func buildChapterImageURL(itemID: String, chapterIndex: Int, imageTag: String, maxWidth: Int) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let path = "/Items/\(itemID)/Images/Chapter/\(chapterIndex)"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        components?.queryItems = [
            // `tag` selects the render and doubles as a cache key (task re-run invalidates it).
            URLQueryItem(name: "tag", value: imageTag),
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return components?.url
    }

    func buildTrickplayTileURL(itemID: String, width: Int, tileIndex: Int) -> URL? {
        guard let baseURL = client.baseURL, let token = client.accessToken else { return nil }
        let path = "/Videos/\(itemID)/Trickplay/\(width)/\(tileIndex).jpg"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "api_key", value: token)]
        return components?.url
    }

    func buildTranscodeURL(relativePath: String) -> URL? {
        guard let baseURL = client.baseURL else { return nil }
        // TranscodingUrl is a path+query WITHOUT the server base path; URL(string:relativeTo:) would anchor at host root and drop a reverse-proxy subpath like "/jellyfin" (404). Splice onto the base components instead. String-assembled (NOT the percentEncoded setters, which fatalError on invalid chars and TranscodingUrl is server-controlled); URL(string:) returns nil instead.
        let trimmed = relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return nil
        }
        let encodedBasePath = components.percentEncodedPath
        let basePath = encodedBasePath.hasSuffix("/") ? String(encodedBasePath.dropLast()) : encodedBasePath
        components.percentEncodedPath = ""
        components.percentEncodedQuery = nil
        guard let root = components.url?.absoluteString else { return nil }
        let rootBase = root.hasSuffix("/") ? String(root.dropLast()) : root
        return URL(string: rootBase + basePath + trimmed)
    }

    /// Direct read of a tuner-backed live channel's own buffered stream (Sodalite#70).
    ///
    /// A tuner host (HDHomeRun and friends) hardcodes `SupportsDirectPlay = false`, so PlaybackInfo
    /// answers with no `TranscodingUrl` and the static `/Videos/{id}/stream.ts?Static=true` route is all
    /// that is left. That route makes the server spawn a second ffmpeg (`-codec copy`) with its own
    /// probe window and a second file on disk, for a client that demuxes MPEG-TS itself. The same
    /// payload's `MediaSource.Path` already names the buffered tuner stream Jellyfin serves anyway
    /// (`LiveTvController.GetLiveStreamFile`, which carries no `[Authorize]`, unlike every other action
    /// in that controller).
    ///
    /// Its HOST is not usable though: the server builds that URL from `GetApiUrlForLocalAccess()`, its
    /// own bind address, so for a client reaching Jellyfin over WAN, a reverse proxy, HTTPS or a VPN
    /// hostname it resolves to nothing and fails as a connection timeout rather than an error. Keep the
    /// server-relative part only and re-anchor it on the URL we are actually connected on, subpath and
    /// all. `api_key` rides along so the request correlates in server logs and survives the route
    /// gaining an authorization policy later; the route ignores it today.
    func buildLiveStreamFileURL(sourcePath: String) -> URL? {
        guard var relative = Self.liveStreamFileRelativePath(fromSourcePath: sourcePath) else { return nil }
        if let token = client.accessToken {
            relative += relative.contains("?") ? "&api_key=\(token)" : "?api_key=\(token)"
        }
        return buildTranscodeURL(relativePath: relative)
    }

    /// The server-relative `/LiveTv/LiveStreamFiles/{streamId}/stream.{ext}` part of a live
    /// `MediaSource.Path`, or nil when the path is not that route. Other tuner hosts put a provider
    /// URL, a local file path or nothing at all in `Path`, and none of those may be handed to the live
    /// loader as though it were Jellyfin's own. Matching from `/LiveTv/` onward rather than on a prefix
    /// also drops whatever base path the server's local URL carries, since `buildTranscodeURL` splices
    /// ours back on.
    static func liveStreamFileRelativePath(fromSourcePath path: String) -> String? {
        guard let components = URLComponents(string: path),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let route = components.percentEncodedPath
        guard let marker = route.range(of: "/LiveTv/LiveStreamFiles/", options: [.caseInsensitive]) else { return nil }
        let tail = String(route[marker.lowerBound...])
        // "", "LiveTv", "LiveStreamFiles", streamId, "stream.ts": both trailing components must be there.
        let parts = tail.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, !parts[3].isEmpty, !parts[4].isEmpty else { return nil }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return tail + "?" + query
        }
        return tail
    }
}

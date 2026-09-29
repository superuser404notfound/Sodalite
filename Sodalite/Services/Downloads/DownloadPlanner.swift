import Foundation

/// Pure decisions of a download (Sodalite#81): which route, which URL, which streams, how big.
enum DownloadPlanner {
    /// Kept free on top of the estimate, so a download never fills the device to the last byte.
    static let spaceHeadroom: Int64 = 512 * 1_048_576

    struct Plan: Equatable, Sendable {
        let route: DownloadRoute
        let url: URL
        let expectedBytes: Int64?
        let sidecarStreams: [MediaStream]
        let localSource: PlaybackMediaSource
        let mediaFileExtension: String

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.route == rhs.route && lhs.url == rhs.url && lhs.expectedBytes == rhs.expectedBytes
                && lhs.sidecarStreams == rhs.sidecarStreams && lhs.localSource.id == rhs.localSource.id
                && lhs.mediaFileExtension == rhs.mediaFileExtension
        }
    }

    static func plan(itemID: String, source: PlaybackMediaSource, quality: StreamingQuality,
                     runtimeTicks: Int64?, audioStreamIndex: Int?, baseURL: URL) -> Plan {
        let streams = source.mediaStreams ?? []
        let isText: (MediaStream) -> Bool = { $0.type == .subtitle && !PlayerViewModel.isBitmapSubtitle($0) }

        if quality.bites(sourceBitrate: source.bitrate),
           let relative = source.transcodingUrl,
           let url = URL(string: relative, relativeTo: baseURL)?.absoluteURL {
            let audio = audioStreamIndex ?? Self.audioStreamIndex(preferredLanguage: nil, streams: streams)
            let kept = streams.filter { $0.type == .video || ($0.type == .audio && $0.index == audio) || isText($0) }
            return Plan(route: .transcode, url: strippingToken(url),
                        expectedBytes: estimatedBytes(quality: quality, sourceBitrate: source.bitrate,
                                                      sourceSize: source.size, runtimeTicks: runtimeTicks),
                        sidecarStreams: streams.filter(isText),
                        localSource: source.replacingStreams(kept),
                        mediaFileExtension: "mp4")
        }

        let url = baseURL.appendingPathComponent("Items").appendingPathComponent(itemID).appendingPathComponent("Download")
        return Plan(route: .original, url: url, expectedBytes: source.size,
                    sidecarStreams: streams.filter { isText($0) && $0.isExternal == true },
                    localSource: source,
                    mediaFileExtension: fileExtension(forContainer: source.container))
    }

    static func estimatedBytes(quality: StreamingQuality, sourceBitrate: Int?, sourceSize: Int64?,
                               runtimeTicks: Int64?) -> Int64? {
        guard quality.bites(sourceBitrate: sourceBitrate), let cap = quality.maxStreamingBitrate else { return sourceSize }
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        return Int64(cap / 8) * (runtimeTicks / 10_000_000)
    }

    static func refusesForSpace(estimate: Int64?, available: Int64?) -> Bool {
        guard let estimate, let available else { return false }
        return estimate + spaceHeadroom > available
    }

    static func failure(forStatus status: Int) -> DownloadFailure? {
        switch status {
        case 200..<300: nil
        case 401: .unauthorized
        case 400, 403: .notAllowed
        default: .server
        }
    }

    /// The track a transcode keeps: the preferred language, else the default track, else the first.
    static func audioStreamIndex(preferredLanguage: String?, streams: [MediaStream]) -> Int? {
        let audio = streams.filter { $0.type == .audio }
        if let preferredLanguage,
           let match = audio.first(where: { sameLanguage($0.language, preferredLanguage) }) {
            return match.index
        }
        return (audio.first { $0.isDefault == true } ?? audio.first)?.index
    }

    static func authorizedRequest(url: URL, authorization: String) -> URLRequest {
        var request = URLRequest(url: strippingToken(url))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    static func strippingToken(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        let kept = components.queryItems?.filter { !["api_key", "apikey"].contains($0.name.lowercased()) }
        components.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        return components.url ?? url
    }

    private static func fileExtension(forContainer container: String?) -> String {
        let first = container?.split(separator: ",").first.map(String.init)?.lowercased() ?? "mkv"
        return first == "matroska" ? "mkv" : first
    }

    private static func sameLanguage(_ a: String?, _ b: String) -> Bool {
        PlayerViewModel.languagesMatch(a, b)
    }
}

extension PlaybackMediaSource {
    /// The same source with another stream list: the local file of a transcode carries fewer streams.
    func replacingStreams(_ streams: [MediaStream]) -> PlaybackMediaSource {
        PlaybackMediaSource(id: id, name: name, path: path, container: container, size: size, bitrate: bitrate,
                            supportsDirectPlay: supportsDirectPlay, supportsDirectStream: supportsDirectStream,
                            supportsTranscoding: supportsTranscoding, transcodingUrl: nil, mediaStreams: streams,
                            liveStreamId: nil, transcodeReasons: nil)
    }
}

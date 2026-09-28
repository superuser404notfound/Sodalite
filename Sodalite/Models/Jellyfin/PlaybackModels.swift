import Foundation

// MARK: - PlaybackInfo Response

struct PlaybackInfoResponse: Codable, Sendable {
    let mediaSources: [PlaybackMediaSource]
    let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

/// A PlaybackInfo response prefetched for ONE item, carrying the id it was fetched for.
///
/// The two never travel apart, because the stream URL is built from BOTH: `item.id` goes in the path
/// and the response's source id into `MediaSourceId`. Crossed, that is
/// `/Videos/{other}/stream.mkv?MediaSourceId={this}`, which Jellyfin answers HTTP 400 (measured: the
/// matching pair returns 206) and the engine reports as "origins answered HTTP 400 for the source".
/// Sodalite#71 crossed them because the guard on the handover read a neighbouring field
/// (`currentEpisodeID`) rather than the response's own identity.
struct PrefetchedPlaybackInfo: Sendable {
    let itemID: String
    /// The rung the response was fetched at (Sodalite#87). A response at another rung describes
    /// another stream: its TranscodingUrl, or its direct-play verdict, belongs to that cap.
    let quality: StreamingQuality
    let response: PlaybackInfoResponse

    /// The response if it describes `itemID` at `quality`, else nil. A caller that cannot say which
    /// item it is launching has no business using a prefetch.
    func matching(_ itemID: String, quality: StreamingQuality) -> PlaybackInfoResponse? {
        self.itemID == itemID && self.quality == quality ? response : nil
    }
}

struct PlaybackMediaSource: Codable, Sendable, Identifiable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingUrl: String?
    let mediaStreams: [MediaStream]?
    /// Set when PlaybackInfo opened a live tuner; echoed on stop + LiveStreams/Close to release it. Nil for VOD.
    let liveStreamId: String?
    /// Transcode reason(s) (e.g. `ContainerNotSupported`, `VideoCodecNotSupported`, `VideoBitrateNotSupported`); decisive signal for full video re-encode vs cheap remux, drives live copy-vs-encode tuning.
    let transcodeReasons: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
        case liveStreamId = "LiveStreamId"
        case transcodeReasons = "TranscodeReasons"
    }
}

// MARK: - Sessions

/// One entry of `GET /Sessions`, decoded down to the two fields a tuner sweep needs (#147).
///
/// Deliberately narrow: `NowPlayingItem` is a full item, and decoding it would drag this small
/// question into the date formats and optionality of the whole library model for nothing. The sweep
/// asks one thing, whether somebody else is on that channel, and these are the two fields that
/// answer it.
struct JellyfinSessionInfo: Decodable, Sendable {
    let deviceID: String?
    let nowPlayingItemID: String?

    private enum CodingKeys: String, CodingKey {
        case deviceId = "DeviceId"
        case nowPlayingItem = "NowPlayingItem"
    }

    private enum ItemKeys: String, CodingKey {
        case id = "Id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceId)
        let item = try? container.nestedContainer(keyedBy: ItemKeys.self, forKey: .nowPlayingItem)
        nowPlayingItemID = try? item?.decodeIfPresent(String.self, forKey: .id)
    }

    init(deviceID: String?, nowPlayingItemID: String?) {
        self.deviceID = deviceID
        self.nowPlayingItemID = nowPlayingItemID
    }
}

// MARK: - Media Segments

/// `/MediaSegments/{itemId}` intro/outro/preview markers; native on Jellyfin 10.10+, intro-skipper plugin on 10.9.
struct MediaSegmentsResponse: Codable, Sendable {
    let items: [MediaSegment]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct MediaSegment: Codable, Sendable, Identifiable {
    let id: String
    let itemId: String
    let type: SegmentType
    let startTicks: Int64
    let endTicks: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemId = "ItemId"
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }

    /// Seconds, 10_000_000 ticks per second.
    var startSeconds: Double { Double(startTicks) / 10_000_000 }
    var endSeconds: Double { Double(endTicks) / 10_000_000 }
}

/// Paired result for one item's intro + outro + recap markers, returned in a
/// single request to `/MediaSegments/{itemId}`. Any of them may be nil if the
/// server didn't detect that segment type.
struct EpisodeSegments: Sendable {
    let intro: MediaSegment?
    let outro: MediaSegment?
    let recap: MediaSegment?
}

enum SegmentType: String, Codable, Sendable {
    case intro = "Intro"
    case outro = "Outro"
    case preview = "Preview"
    case recap = "Recap"
    case commercial = "Commercial"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SegmentType(rawValue: raw) ?? .unknown
    }
}

// MARK: - Session Reports

struct PlaybackStartReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let playSessionId: String?
    let positionTicks: Int64
    let canSeek: Bool
    let playMethod: PlayMethod
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}

struct PlaybackProgressReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let playSessionId: String?
    let positionTicks: Int64
    let isPaused: Bool
    let canSeek: Bool
    let playMethod: PlayMethod
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}

struct PlaybackStopReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String
    let playSessionId: String?
    let positionTicks: Int64
    /// Non-nil only for live streams; tells the server which tuner to
    /// release on stop.
    let liveStreamId: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case liveStreamId = "LiveStreamId"
    }
}

// MARK: - Play Method

enum PlayMethod: String, Encodable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

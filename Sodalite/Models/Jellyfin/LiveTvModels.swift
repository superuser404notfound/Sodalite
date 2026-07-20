import Foundation

/// A Live TV channel (server-side a `BaseItemDto` of type `TvChannel`); decodes only the guide's fields.
struct JellyfinChannel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let channelNumber: String?
    let imageTags: [String: String]?
    /// Present when the channel list is fetched with `addCurrentProgram=true`.
    let currentProgram: JellyfinProgram?
    /// Present when the channel list is fetched with `EnableUserData=true`.
    let userData: ChannelUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case channelNumber = "ChannelNumber"
        case imageTags = "ImageTags"
        case currentProgram = "CurrentProgram"
        case userData = "UserData"
    }

    /// Primary image tag, used to build the channel-logo URL.
    var primaryImageTag: String? { imageTags?["Primary"] }

    /// Server-side favorite flag (nil when UserData wasn't requested).
    var isFavorite: Bool { userData?.isFavorite ?? false }
}

/// Channel `UserData` slice the guide reads; favorites use the same UserData.IsFavorite as regular items.
struct ChannelUserData: Codable, Sendable, Equatable {
    let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
    }
}

/// A single EPG program. Server-side a `BaseItemDto` of type `Program`.
struct JellyfinProgram: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let channelId: String?
    let channelName: String?
    let name: String
    let overview: String?
    let startDate: Date?
    let endDate: Date?
    let genres: [String]?
    let imageTags: [String: String]?
    let isLive: Bool?
    let isNews: Bool?
    let isMovie: Bool?
    let isSeries: Bool?
    let isKids: Bool?
    let isSports: Bool?
    /// Series name for episode-type programs (populated when the EPG source provides it).
    let seriesName: String?
    /// Season number for episode-type programs.
    let parentIndexNumber: Int?
    /// Episode number within its season.
    let indexNumber: Int?
    /// The episode title, separate from `name` (available when the EPG source provides it).
    let episodeTitle: String?
    /// Set when a single-program record timer exists for this program.
    let timerId: String?
    /// Set when a series timer covers this program.
    let seriesTimerId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case channelId = "ChannelId"
        case channelName = "ChannelName"
        case name = "Name"
        case overview = "Overview"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case genres = "Genres"
        case imageTags = "ImageTags"
        case isLive = "IsLive"
        case isNews = "IsNews"
        case isMovie = "IsMovie"
        case isSeries = "IsSeries"
        case isKids = "IsKids"
        case isSports = "IsSports"
        case seriesName = "SeriesName"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case episodeTitle = "EpisodeTitle"
        case timerId = "TimerId"
        case seriesTimerId = "SeriesTimerId"
    }

    var primaryImageTag: String? { imageTags?["Primary"] }

    /// Guide placeholder for channels without EPG data ("live-<channelID>"); id doesn't exist server-side, so don't offer record affordances.
    var isSynthesized: Bool { id.hasPrefix("live-") }

    /// True when `now` falls inside [startDate, endDate).
    func isAiring(at now: Date) -> Bool {
        guard let start = startDate, let end = endDate else { return false }
        return now >= start && now < end
    }
}

/// Global EPG bounds from `/LiveTv/GuideInfo`; sets the guide's time axis.
struct JellyfinGuideInfo: Codable, Sendable, Equatable {
    let startDate: Date?
    let endDate: Date?

    enum CodingKeys: String, CodingKey {
        case startDate = "StartDate"
        case endDate = "EndDate"
    }
}

/// `/LiveTv/Channels` and `/LiveTv/Programs` both return the standard
/// `{ Items, TotalRecordCount }` envelope.
struct LiveTvChannelsResponse: Codable, Sendable {
    let items: [JellyfinChannel]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct LiveTvProgramsResponse: Codable, Sendable {
    let items: [JellyfinProgram]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// Recording timer status from `/LiveTv/Timers`. Unknown server values decode to `.unknown` rather than failing the whole timer (mirrors `SegmentType`).
enum LiveTimerStatus: String, Codable, Sendable, Equatable {
    case new = "New"
    case inProgress = "InProgress"
    case completed = "Completed"
    case cancelled = "Cancelled"
    case error = "Error"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = LiveTimerStatus(rawValue: raw) ?? .unknown
    }
}

/// A scheduled single-program recording (`/LiveTv/Timers`).
struct LiveTvTimer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let programId: String?
    let channelId: String?
    let name: String?
    let channelName: String?
    let startDate: Date?
    let endDate: Date?
    /// Set when this timer was spawned by a series timer.
    let seriesTimerId: String?
    let status: LiveTimerStatus?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case programId = "ProgramId"
        case channelId = "ChannelId"
        case name = "Name"
        case channelName = "ChannelName"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case seriesTimerId = "SeriesTimerId"
        case status = "Status"
    }
}

/// A series recording rule (`/LiveTv/SeriesTimers`).
struct LiveTvSeriesTimer: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String?
    let channelName: String?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case channelName = "ChannelName"
        case overview = "Overview"
    }
}

struct LiveTvTimersResponse: Codable, Sendable {
    let items: [LiveTvTimer]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct LiveTvSeriesTimersResponse: Codable, Sendable {
    let items: [LiveTvSeriesTimer]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

extension JSONDecoder {
    /// Lenient ISO parse: Jellyfin timestamps carry up to 7 fractional digits + `Z`, which `.iso8601` (max 3) rejects.
    static let jellyfinLiveTv: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            // Per-call DateFormatter: shared instance would race on `dateFormat` across overlapping Live TV requests.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS'Z'",
                        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                        "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
                formatter.dateFormat = fmt
                if let date = formatter.date(from: raw) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unparseable date: \(raw)")
        }
        return decoder
    }()
}

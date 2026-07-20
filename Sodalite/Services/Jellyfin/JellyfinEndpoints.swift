import Foundation

enum JellyfinEndpoint: APIEndpoint {
    // Server
    case publicInfo
    case publicUsers

    // Auth
    case authenticateByName(username: String, password: String)
    case currentUser

    // Quick Connect
    case quickConnectInitiate
    case quickConnectCheck(secret: String)
    case quickConnectAuthenticate(secret: String)

    // Libraries
    case userViews(userID: String)

    // Items
    case items(userID: String, query: ItemQuery)
    case itemDetail(userID: String, itemID: String)
    /// GET LocalTrailers: bare BaseItemDto array (not the {Items:[...]} envelope); each is a playable item with its own id.
    case localTrailers(userID: String, itemID: String)
    case resumeItems(userID: String, mediaType: String, limit: Int)
    case nextUp(userID: String, seriesID: String?, limit: Int, rewatching: Bool)
    case latestMedia(userID: String, parentID: String?, includeItemTypes: [ItemType]?, limit: Int)
    case seasons(seriesID: String, userID: String)
    case episodes(seriesID: String, seasonID: String, userID: String)
    case similarItems(itemID: String, userID: String, limit: Int)
    /// DELETE /Items/{itemID}; Jellyfin cascades series→seasons→episodes server-side, called once per item.
    case deleteItem(itemID: String)

    // Genres & Studios
    case genres(userID: String)
    case studios(userID: String)

    // PlaybackInfo body is the DeviceProfile dict (DirectPlayProfile [String: Any]) bridged through JSONValue for the Encodable body path.
    case playbackInfo(itemID: String, userID: String, payload: JSONValue)
    case livePlaybackInfo(itemID: String, userID: String, maxStreamingBitrate: Int, payload: JSONValue)
    case sessionPlaying(report: PlaybackStartReport)
    case sessionProgress(report: PlaybackProgressReport)
    case sessionStopped(report: PlaybackStopReport)

    // Favorites
    case markFavorite(userID: String, itemID: String)
    case unmarkFavorite(userID: String, itemID: String)

    // Played
    case markPlayed(userID: String, itemID: String)
    case unmarkPlayed(userID: String, itemID: String)

    // Search
    case searchHints(userID: String, query: String, limit: Int)

    // Intro/Outro markers (Jellyfin 10.10+ native, or intro-skipper plugin on older servers)
    case mediaSegments(itemID: String)

    // Subtitle RemoteSearch needs a server-side provider plugin (e.g. OpenSubtitles). `subtitleID` is provider-scoped, can contain slashes, so percent-encoded into the path.
    case remoteSearchSubtitles(itemID: String, language: String)
    case downloadRemoteSubtitle(itemID: String, subtitleID: String)
    /// DELETE external subtitle; needs subtitle-management rights.
    case deleteSubtitle(itemID: String, index: Int)

    // Live TV
    case liveTvChannels(userID: String, startIndex: Int, limit: Int)
    case liveTvPrograms(channelIDs: [String], userID: String, minEndDate: Date, maxStartDate: Date)
    case liveTvRecommendedPrograms(userID: String, category: LiveProgramCategory, limit: Int)
    case liveTvGuideInfo
    case closeLiveStream(liveStreamID: String)
    /// DELETE /Videos/ActiveEncodings: kill the transcode for this (device, play session) + its output. Without it a live transcode whose PlaybackStopped is lost (app kill/crash) keeps ffmpeg growing stream.ts until the disk fills.
    case stopActiveEncodings(deviceID: String, playSessionID: String)
    case liveTvRecordings(userID: String, isInProgress: Bool?)
    case liveTvTimers
    case liveTvSeriesTimers
    case liveTvTimerDefaults(programID: String)
    case createLiveTvTimer(payload: JSONValue)
    case deleteLiveTvTimer(timerID: String)
    case createLiveTvSeriesTimer(payload: JSONValue)
    case deleteLiveTvSeriesTimer(timerID: String)

    var path: String {
        switch self {
        case .publicInfo:
            "/System/Info/Public"
        case .publicUsers:
            "/Users/Public"
        case .authenticateByName:
            "/Users/AuthenticateByName"
        case .currentUser:
            "/Users/Me"
        case .quickConnectInitiate:
            "/QuickConnect/Initiate"
        case .quickConnectCheck:
            "/QuickConnect/Connect"
        case .quickConnectAuthenticate:
            "/Users/AuthenticateWithQuickConnect"
        case .userViews(let userID):
            "/Users/\(userID)/Views"
        case .items(let userID, _):
            "/Users/\(userID)/Items"
        case .itemDetail(let userID, let itemID):
            "/Users/\(userID)/Items/\(itemID)"
        case .localTrailers(let userID, let itemID):
            "/Users/\(userID)/Items/\(itemID)/LocalTrailers"
        case .resumeItems(let userID, _, _):
            "/Users/\(userID)/Items/Resume"
        case .nextUp:
            "/Shows/NextUp"
        case .latestMedia(let userID, _, _, _):
            "/Users/\(userID)/Items/Latest"
        case .seasons(let seriesID, _):
            "/Shows/\(seriesID)/Seasons"
        case .episodes(let seriesID, _, _):
            "/Shows/\(seriesID)/Episodes"
        case .similarItems(let itemID, _, _):
            "/Items/\(itemID)/Similar"
        case .deleteItem(let itemID):
            "/Items/\(itemID)"
        case .genres:
            "/Genres"
        case .studios:
            "/Studios"
        case .playbackInfo(let itemID, _, _), .livePlaybackInfo(let itemID, _, _, _):
            "/Items/\(itemID)/PlaybackInfo"
        case .sessionPlaying:
            "/Sessions/Playing"
        case .sessionProgress:
            "/Sessions/Playing/Progress"
        case .sessionStopped:
            "/Sessions/Playing/Stopped"
        case .markFavorite(let userID, let itemID):
            "/Users/\(userID)/FavoriteItems/\(itemID)"
        case .unmarkFavorite(let userID, let itemID):
            "/Users/\(userID)/FavoriteItems/\(itemID)"
        case .markPlayed(let userID, let itemID):
            "/Users/\(userID)/PlayedItems/\(itemID)"
        case .unmarkPlayed(let userID, let itemID):
            "/Users/\(userID)/PlayedItems/\(itemID)"
        case .searchHints:
            "/Search/Hints"
        case .mediaSegments(let itemID):
            "/MediaSegments/\(itemID)"
        case .remoteSearchSubtitles(let itemID, let language):
            "/Items/\(itemID)/RemoteSearch/Subtitles/\(language)"
        case .deleteSubtitle(let itemID, let index):
            "/Videos/\(itemID)/Subtitles/\(index)"
        case .downloadRemoteSubtitle(let itemID, let subtitleID):
            "/Items/\(itemID)/RemoteSearch/Subtitles/\(subtitleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? subtitleID)"
        case .liveTvChannels:
            "/LiveTv/Channels"
        case .liveTvPrograms:
            "/LiveTv/Programs"
        case .liveTvRecommendedPrograms:
            "/LiveTv/Programs/Recommended"
        case .liveTvGuideInfo:
            "/LiveTv/GuideInfo"
        case .closeLiveStream:
            "/LiveTv/LiveStreams/Close"
        case .stopActiveEncodings:
            "/Videos/ActiveEncodings"
        case .liveTvRecordings:
            "/LiveTv/Recordings"
        case .liveTvTimers, .createLiveTvTimer:
            "/LiveTv/Timers"
        case .liveTvSeriesTimers, .createLiveTvSeriesTimer:
            "/LiveTv/SeriesTimers"
        case .liveTvTimerDefaults:
            "/LiveTv/Timers/Defaults"
        case .deleteLiveTvTimer(let timerID):
            "/LiveTv/Timers/\(timerID)"
        case .deleteLiveTvSeriesTimer(let timerID):
            "/LiveTv/SeriesTimers/\(timerID)"
        }
    }

    var percentEncodedPath: String? {
        switch self {
        case .downloadRemoteSubtitle(let itemID, let subtitleID):
            let encodedID = subtitleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? subtitleID
            return "/Items/\(itemID)/RemoteSearch/Subtitles/\(encodedID)"
        default:
            return nil
        }
    }

    var method: HTTPMethod {
        switch self {
        case .authenticateByName, .quickConnectInitiate, .quickConnectAuthenticate, .markFavorite,
             .markPlayed,
             .playbackInfo, .livePlaybackInfo,
             .sessionPlaying, .sessionProgress, .sessionStopped,
             .closeLiveStream,
             .createLiveTvTimer, .createLiveTvSeriesTimer,
             .downloadRemoteSubtitle:
            .post
        case .unmarkFavorite, .unmarkPlayed, .deleteItem, .stopActiveEncodings,
             .deleteLiveTvTimer, .deleteLiveTvSeriesTimer, .deleteSubtitle:
            .delete
        default:
            .get
        }
    }

    /// 90s for fire-and-forget session writes: a 30s drop on a slow CDN origin loses the position and strands a stale resume point (Sodalite#12). Everything else keeps 30s.
    var timeoutInterval: TimeInterval? {
        switch self {
        case .sessionPlaying, .sessionProgress, .sessionStopped:
            return 90
        case .playbackInfo, .livePlaybackInfo:
            // 60s (its old URLSession.shared ceiling); live AutoOpenLiveStream probes the tuner server-side and slow IPTV tuners exceed 30s.
            return 60
        default:
            return nil
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .quickConnectCheck(let secret):
            return [URLQueryItem(name: "secret", value: secret)]

        case .playbackInfo(_, let userID, _):
            return [URLQueryItem(name: "UserId", value: userID)]

        case .livePlaybackInfo(_, let userID, let maxStreamingBitrate, _):
            // AutoOpenLiveStream probes the tuner (known codecs → DirectStream/copy, real LiveStreamId); IsPlayback marks a real play; MaxStreamingBitrate caps a transcode fallback.
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "AutoOpenLiveStream", value: "true"),
                URLQueryItem(name: "IsPlayback", value: "true"),
                URLQueryItem(name: "StartTimeTicks", value: "0"),
                URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate)),
            ]

        case .items(_, let query):
            return query.toQueryItems()

        case .localTrailers(let userID, _):
            // UserId for user data; defaultFields so trailers arrive with MediaSources/Chapters like a playable detail item.
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Fields", value: Self.defaultFields),
            ]

        case .itemDetail:
            // Needs explicit defaultFields (rich detail), incl. LocalTrailerCount so the Trailer button gates without a second round-trip.
            return [URLQueryItem(name: "Fields", value: Self.defaultFields)]

        case .resumeItems(_, let mediaType, let limit):
            return [
                URLQueryItem(name: "MediaTypes", value: mediaType),
                URLQueryItem(name: "Limit", value: String(limit)),
                // Continue Watching is a Home carousel + resume deep-link; slim homeRowFields suffices.
                URLQueryItem(name: "Fields", value: Self.homeRowFields),
            ]

        case .nextUp(let userID, let seriesID, let limit, let rewatching):
            var items = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Limit", value: String(limit)),
                // Next Up is a Home carousel + series-detail play button; slim homeRowFields suffices.
                URLQueryItem(name: "Fields", value: Self.homeRowFields),
                // EnableResumable=false: keep partially-watched episodes out of Next Up (else they double up with Continue Watching, the two rows fetch independently with no client dedup). Ignored by older servers.
                URLQueryItem(name: "EnableResumable", value: "false"),
            ]
            // EnableRewatching: surface the next episode even on a fully-watched series. Orthogonal to EnableResumable; only sent when on so older servers keep prior behaviour.
            if rewatching {
                items.append(URLQueryItem(name: "EnableRewatching", value: "true"))
            }
            if let seriesID {
                items.append(URLQueryItem(name: "SeriesId", value: seriesID))
            }
            return items

        case .latestMedia(_, let parentID, let includeItemTypes, let limit):
            var items = [
                URLQueryItem(name: "Limit", value: String(limit)),
                // Latest rows are Home carousels; slim homeRowFields.
                URLQueryItem(name: "Fields", value: Self.homeRowFields),
            ]
            if let parentID {
                items.append(URLQueryItem(name: "ParentId", value: parentID))
            }
            if let includeItemTypes {
                // Without IncludeItemTypes, dropping ParentId makes the row a movie+series+music jumble instead of a typed "Latest Movies"/"Latest Shows".
                items.append(URLQueryItem(
                    name: "IncludeItemTypes",
                    value: includeItemTypes.map(\.rawValue).joined(separator: ",")
                ))
            }
            return items

        case .seasons(_, let userID):
            return [
                URLQueryItem(name: "UserId", value: userID),
                // seasonListFields, NOT defaultFields: getSeasons gates the whole season+episode section and was the slowest detail round-trip on slow CDNs.
                URLQueryItem(name: "Fields", value: Self.seasonListFields),
            ]

        case .episodes(_, let seasonID, let userID):
            return [
                URLQueryItem(name: "SeasonId", value: seasonID),
                URLQueryItem(name: "UserId", value: userID),
                // episodeListFields, NOT defaultFields: dropping the heavy per-episode arrays is the big win on slow servers; episode detail (TechInfoBox) pulls the full set lazily on open.
                URLQueryItem(name: "Fields", value: Self.episodeListFields),
            ]

        case .similarItems(_, let userID, let limit):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "Limit", value: String(limit)),
            ]

        case .genres(let userID):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]

        case .studios(let userID):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]

        case .searchHints(let userID, let query, let limit):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "SearchTerm", value: query),
                URLQueryItem(name: "Limit", value: String(limit)),
            ]

        case .mediaSegments:
            // Intro (skip button) + Outro (early next-episode overlay). Repeated same-name items bind ASP.NET's list parameter.
            return [
                URLQueryItem(name: "includeSegmentTypes", value: "Intro"),
                URLQueryItem(name: "includeSegmentTypes", value: "Outro"),
            ]

        case .liveTvChannels(let userID, let startIndex, let limit):
            return [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "AddCurrentProgram", value: "true"),
                // Server-side favorite sorting (via UserData IsFavorite) keeps StartIndex pagination + incremental diffing intact, which a client re-sort would break.
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableFavoriteSorting", value: "true"),
            ]

        case .liveTvPrograms(let channelIDs, let userID, let minEnd, let maxStart):
            // Local formatter: ISO8601DateFormatter isn't Sendable so can't be a shared static; these requests are low-frequency.
            let iso = ISO8601DateFormatter()
            return [
                URLQueryItem(name: "ChannelIds", value: channelIDs.joined(separator: ",")),
                URLQueryItem(name: "UserId", value: userID),
                // Overlap, NOT containment (MinEndDate + MaxStartDate): the old MinStartDate filter dropped programs airing RIGHT NOW, emptying the EPG's first column.
                URLQueryItem(name: "MinEndDate", value: iso.string(from: minEnd)),
                URLQueryItem(name: "MaxStartDate", value: iso.string(from: maxStart)),
                URLQueryItem(name: "SortBy", value: "StartDate"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "Fields", value: "Overview,SeriesName,ParentIndexNumber,IndexNumber,EpisodeTitle"),
            ]

        case .liveTvRecommendedPrograms(let userID, let category, let limit):
            let flag: URLQueryItem = switch category {
            case .airing: URLQueryItem(name: "IsAiring", value: "true")
            case .series: URLQueryItem(name: "IsSeries", value: "true")
            case .movies: URLQueryItem(name: "IsMovie", value: "true")
            case .sports: URLQueryItem(name: "IsSports", value: "true")
            case .kids:   URLQueryItem(name: "IsKids", value: "true")
            case .news:   URLQueryItem(name: "IsNews", value: "true")
            }
            return [
                URLQueryItem(name: "UserId", value: userID),
                flag,
                URLQueryItem(name: "EnableImages", value: "true"),
                // ChannelInfo populates ChannelName so the card subtitle + synthesized JellyfinChannel have a name without a channel fetch.
                URLQueryItem(name: "Fields", value: "ChannelInfo,Overview,SeriesName,ParentIndexNumber,IndexNumber,EpisodeTitle"),
                URLQueryItem(name: "SortBy", value: "StartDate"),
                URLQueryItem(name: "Limit", value: String(limit)),
            ]

        case .closeLiveStream(let liveStreamID):
            return [URLQueryItem(name: "LiveStreamId", value: liveStreamID)]

        case .stopActiveEncodings(let deviceID, let playSessionID):
            return [
                URLQueryItem(name: "deviceId", value: deviceID),
                URLQueryItem(name: "playSessionId", value: playSessionID),
            ]

        case .liveTvRecordings(let userID, let isInProgress):
            var items = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "Fields", value: "Overview"),
                // userData.playbackPositionTicks drives resume, matching liveTvChannels.
                URLQueryItem(name: "EnableUserData", value: "true"),
            ]
            // Modern Jellyfin leaves BaseItemDto.Status empty on recordings; the IsInProgress filter is how jellyfin-web finds active ones (verified against the live server).
            if let isInProgress {
                items.append(URLQueryItem(name: "IsInProgress", value: isInProgress ? "true" : "false"))
            }
            return items

        case .liveTvTimerDefaults(let programID):
            return [URLQueryItem(name: "programId", value: programID)]

        default:
            return nil
        }
    }

    var body: (any Encodable & Sendable)? {
        switch self {
        case .authenticateByName(let username, let password):
            AuthenticateBody(username: username, pw: password)
        case .quickConnectAuthenticate(let secret):
            QuickConnectAuthBody(secret: secret)
        case .playbackInfo(_, _, let payload), .livePlaybackInfo(_, _, _, let payload):
            payload
        case .sessionPlaying(let report):
            report
        case .sessionProgress(let report):
            report
        case .sessionStopped(let report):
            report
        case .createLiveTvTimer(let payload), .createLiveTvSeriesTimer(let payload):
            payload
        default:
            nil
        }
    }

    var requiresAuth: Bool {
        switch self {
        case .publicInfo, .publicUsers, .authenticateByName, .quickConnectInitiate, .quickConnectCheck:
            false
        default:
            true
        }
    }

    static let defaultFields = "Overview,Genres,People,Studios,MediaStreams,MediaSources,CommunityRating,CriticRating,OfficialRating,ImageTags,BackdropImageTags,ParentBackdropImageTags,SeriesPrimaryImageTag,ProviderIds,Chapters,LocalTrailerCount,Trickplay"

    /// Season bar: ItemCounts keeps childCount (skeleton sizing) without defaultFields' heavy arrays. Name/index/watched are base/UserData fields.
    static let seasonListFields = "ItemCounts"

    /// Episode list: only synopsis + thumbnail; name/index/runtime/watched are base/UserData. Heavy per-episode arrays omitted, episode detail pulls them lazily on open.
    static let episodeListFields = "Overview,ImageTags"

    /// Home carousels: image tags only; title/year/series/watched ride as base/UserData fields. defaultFields per item is dead weight on 16-30-item rows (Sodalite#12 Fields= audit); tapping a card re-fetches full fields in Detail. `nonisolated` so detached precompute closures read it without a MainActor hop (immutable, so cross-actor safe).
    nonisolated static let homeRowFields = "ImageTags,BackdropImageTags,ParentBackdropImageTags,SeriesPrimaryImageTag"

    /// Music browse rows: image tags + album/artist linkage; IndexNumber/ParentIndexNumber/RunTimeTicks/ProductionYear come back without an explicit Fields request.
    nonisolated static let musicListFields = "ImageTags,Artists,AlbumArtist,AlbumId,AlbumPrimaryImageTag"
}

struct ItemQuery: Sendable {
    var parentID: String?
    /// `Ids=` lookup; batch-resolves parent series for episodes /Items/Latest returns ungrouped (series with one fresh episode).
    var ids: [String]?
    var includeItemTypes: [ItemType]?
    var sortBy: String?
    var sortOrder: String?
    var limit: Int?
    var startIndex: Int?
    var searchTerm: String?
    var genres: [String]?
    var studioNames: [String]?
    var isFavorite: Bool?
    /// Jellyfin `Filters` (IsPlayed/IsUnplayed/IsResumable); drives the library-grid watch-status filter (Sodalite#17).
    var filters: [String]?
    /// Single provider-id match ("tmdb.123"). `AnyProviderIdEquals` takes one value only, so the home smart-provider filter fans out multi-id lookups as parallel queries.
    var anyProviderIdEquals: String?
    var fields: String?

    func toQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        if let parentID { items.append(URLQueryItem(name: "ParentId", value: parentID)) }
        if let ids {
            items.append(URLQueryItem(name: "Ids", value: ids.joined(separator: ",")))
        }
        if let types = includeItemTypes {
            items.append(URLQueryItem(name: "IncludeItemTypes", value: types.map(\.rawValue).joined(separator: ",")))
        }
        if let sortBy { items.append(URLQueryItem(name: "SortBy", value: sortBy)) }
        if let sortOrder { items.append(URLQueryItem(name: "SortOrder", value: sortOrder)) }
        if let limit { items.append(URLQueryItem(name: "Limit", value: String(limit))) }
        if let startIndex { items.append(URLQueryItem(name: "StartIndex", value: String(startIndex))) }
        if let searchTerm { items.append(URLQueryItem(name: "SearchTerm", value: searchTerm)) }
        if let genres {
            items.append(URLQueryItem(name: "Genres", value: genres.joined(separator: "|")))
        }
        if let studioNames {
            items.append(URLQueryItem(name: "Studios", value: studioNames.joined(separator: "|")))
        }
        if let isFavorite { items.append(URLQueryItem(name: "IsFavorite", value: String(isFavorite))) }
        if let filters {
            items.append(URLQueryItem(name: "Filters", value: filters.joined(separator: ",")))
        }
        if let anyProviderIdEquals {
            items.append(URLQueryItem(name: "AnyProviderIdEquals", value: anyProviderIdEquals))
        }

        let fields = fields ?? JellyfinEndpoint.defaultFields
        items.append(URLQueryItem(name: "Fields", value: fields))
        items.append(URLQueryItem(name: "Recursive", value: "true"))
        // CollapseBoxSetItems defaults true for Movie queries (folds BoxSet members into one row, even for silent TMDB-created collections); force false so each movie stands alone. The Collections row uses a dedicated BoxSet query, unaffected.
        items.append(URLQueryItem(name: "CollapseBoxSetItems", value: "false"))

        return items
    }
}

private struct AuthenticateBody: Encodable, Sendable {
    let username: String
    let pw: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}

private struct QuickConnectAuthBody: Encodable, Sendable {
    let secret: String

    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
    }
}
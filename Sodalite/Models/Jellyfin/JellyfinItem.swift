import Foundation

struct JellyfinItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let sortName: String?
    let originalTitle: String?
    let overview: String?
    let type: ItemType
    let seriesName: String?
    let seriesId: String?
    let seasonId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let productionYear: Int?
    let communityRating: Double?
    /// Rotten Tomatoes critic score (0-100); nil unless a metadata provider (OMDb) delivers it.
    let criticRating: Double?
    let officialRating: String?  // e.g. "PG-13"
    let runTimeTicks: Int64?
    let premiereDate: String?
    let endDate: String?
    let status: String?
    let genres: [String]?
    let taglines: [String]?
    let imageTags: ImageTags?
    let backdropImageTags: [String]?
    let parentBackdropImageTags: [String]?
    // `var` so detail views patch the in-memory resume position from the playback-stop payload (issue #24), no re-fetch.
    var userData: UserItemData?
    /// Item-level video geometry (`Fields=Width,Height`): two ints read straight off the BaseItem
    /// row, no MediaSourceManager call, so the resolution pill costs nothing on a 200-item grid
    /// (Sodalite#79). `var` with a default so the hand-written inits below stay untouched.
    var width: Int?
    var height: Int?
    let mediaStreams: [MediaStream]?
    let mediaSources: [MediaSource]?
    let people: [PersonInfo]?
    let studios: [StudioInfo]?
    let collectionType: String?
    /// Jellyfin `CanDelete`, the server's own answer for THIS item and THIS user. It folds in what
    /// the user policy alone cannot see: `EnableContentDeletionFromFolders`, which is how an admin
    /// says "the DVR library may be deleted from and the rest may not". The single-item endpoint
    /// builds its DtoOptions with every field, so detail responses carry it unasked; a list response
    /// carries it only when `Fields` names it, which no query here does. `var` with no default so
    /// the hand-written inits below stay untouched, and nil falls back to the user policy.
    var canDelete: Bool?
    /// Jellyfin `RecursiveItemCount`: for a series, how many episodes sit under it. Same delivery
    /// rule as `canDelete` above, so a detail response carries it and a list response does not,
    /// which is why every reader has to survive nil rather than print a zero (Sodalite#146 round 3).
    var recursiveItemCount: Int?
    /// Jellyfin `LocationType`. Carried on every /Items response without asking for a Field, and
    /// "Virtual" is the only value that matters here (see `isVirtual`). `var` with a default so the
    /// hand-written inits below stay untouched.
    var locationType: String?
    /// Jellyfin `MediaType` ("Video"/"Audio"/...). Carried on every /Items response without asking
    /// for a Field. On a Playlist it reports the playlist's own kind, which is the only way to tell
    /// an audio playlist apart from a video one (see `isAudioPlaylist`). `var` with a default so
    /// the hand-written inits below stay untouched.
    var mediaType: String?
    /// Jellyfin `ServerId`, on every BaseItemDto. nil on items cached before it was decoded, which
    /// resolve against the active server (Sodalite#85).
    var serverID: String?
    /// Jellyfin `DateCreated` (card field set), the sort key a combined Home's Latest rows merge by.
    var dateCreated: String?
    let childCount: Int?
    /// Local trailer count (requires LocalTrailerCount in Fields); gates the detail Trailer button. nil if unrequested.
    let localTrailerCount: Int?
    /// Extras from the item's extras/clips/featurettes folders (requires SpecialFeatureCount in Fields); gates the detail Extras row. nil if unrequested.
    let specialFeatureCount: Int?
    let seriesPrimaryImageTag: String?
    let providerIds: [String: String]?
    /// nil unless the fetch requested `Fields=Chapters`; `[]` is the server answering "none". `var`
    /// so the player can fill it from its own detail fetch when a slim list item reaches it (Sodalite#94).
    var chapters: [ChapterInfo]?
    /// Trickplay manifest: mediaSourceId -> width-string -> rendition. nil unless the server
    /// generated tiles and the fetch requested `Fields=Trickplay`. `var` for the same reason as `chapters`.
    var trickplay: [String: [String: TrickplayInfo]]?
    let albumArtist: String?
    let artists: [String]?
    let albumId: String?
    let albumPrimaryImageTag: String?

    /// Display line for a track: the per-track artists if present,
    /// otherwise the album artist. nil when neither is set.
    var trackArtistLine: String? {
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        return albumArtist
    }

    /// TMDB id (correlates with Seerr). Key is case-sensitive ("Tmdb"); older scanners wrote "tmdb", so check both.
    var tmdbID: Int? {
        guard let ids = providerIds else { return nil }
        let raw = ids["Tmdb"] ?? ids["tmdb"] ?? ids["TMDB"]
        return raw.flatMap(Int.init)
    }

    /// IMDb id ("tt0133093"). Case-insensitive for the same reason `tmdbID` checks three spellings:
    /// scanners disagree on the key.
    var imdbID: String? { providerID(named: "Imdb") }

    /// TVDB id, which some libraries carry where TMDB is missing.
    var tvdbID: Int? { providerID(named: "Tvdb").flatMap(Int.init) }

    private func providerID(named key: String) -> String? {
        providerIds?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// An entry the library lists but holds no file for: a missing or an unaired episode. Jellyfin
    /// returns those alongside real ones whenever the user has "display missing episodes" on, and
    /// they cannot be opened or played, so any row that promises library content drops them
    /// (Sodalite#57).
    var isVirtual: Bool {
        locationType?.caseInsensitiveCompare("Virtual") == .orderedSame
    }

    /// A playlist of songs. Jellyfin fixes a playlist's media type at creation and reports it on
    /// the item, and the video playlist screen shows nothing but video leaves, so an audio playlist
    /// opened from a video row is a dead end: no list, and Play/Shuffle with an empty queue.
    var isAudioPlaylist: Bool {
        type == .playlist && mediaType?.caseInsensitiveCompare("Audio") == .orderedSame
    }

    /// Time left, for the resume capsule's label (Sodalite#99). `nil` unless the item carries a real
    /// resume point, which is the gate that keeps container items honest: a series or an album has a
    /// `playedPercentage` (episodes watched, tracks played) but never a `playbackPositionTicks`, so
    /// subtracting a missing position from the runtime would have advertised a whole album as "left
    /// to play". Under a minute counts as nothing left, since the label would round it to "1m".
    var resumeRemainingTicks: Int64? {
        guard let total = runTimeTicks,
              let position = userData?.playbackPositionTicks,
              position > 0
        else { return nil }
        let remaining = total - position
        return remaining >= 60 * 10_000_000 ? remaining : nil
    }

    /// Does this item actually carry `provider.value` (e.g. "tmdb.1399")? Jellyfin has no server-side
    /// provider-id filter, so a query that looks like a lookup returns whatever the library sorts first;
    /// every such "hit" has to be verified here or it is just an arbitrary item.
    func carriesProviderID(_ qualified: String) -> Bool {
        let parts = qualified.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let ids = providerIds else { return false }
        let provider = parts[0].lowercased()
        let value = parts[1].lowercased()
        return ids.contains { $0.key.lowercased() == provider && $0.value.lowercased() == value }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case sortName = "SortName"
        case originalTitle = "OriginalTitle"
        case overview = "Overview"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case officialRating = "OfficialRating"
        case runTimeTicks = "RunTimeTicks"
        case premiereDate = "PremiereDate"
        case endDate = "EndDate"
        case status = "Status"
        case genres = "Genres"
        case taglines = "Taglines"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case userData = "UserData"
        case width = "Width"
        case height = "Height"
        case mediaStreams = "MediaStreams"
        case mediaSources = "MediaSources"
        case people = "People"
        case studios = "Studios"
        case collectionType = "CollectionType"
        case canDelete = "CanDelete"
        case recursiveItemCount = "RecursiveItemCount"
        case locationType = "LocationType"
        case mediaType = "MediaType"
        case serverID = "ServerId"
        case dateCreated = "DateCreated"
        case childCount = "ChildCount"
        case localTrailerCount = "LocalTrailerCount"
        case specialFeatureCount = "SpecialFeatureCount"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case providerIds = "ProviderIds"
        case chapters = "Chapters"
        case trickplay = "Trickplay"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case albumId = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
    }

    init(seriesStub id: String, name: String) {
        self.id = id
        self.name = name
        self.sortName = nil
        self.originalTitle = nil
        self.overview = nil
        self.type = .series
        self.seriesName = nil
        self.seriesId = nil
        self.seasonId = nil
        self.parentIndexNumber = nil
        self.indexNumber = nil
        self.productionYear = nil
        self.communityRating = nil
        self.criticRating = nil
        self.officialRating = nil
        self.runTimeTicks = nil
        self.premiereDate = nil
        self.endDate = nil
        self.status = nil
        self.genres = nil
        self.taglines = nil
        self.imageTags = nil
        self.backdropImageTags = nil
        self.parentBackdropImageTags = nil
        self.userData = nil
        self.mediaStreams = nil
        self.mediaSources = nil
        self.people = nil
        self.studios = nil
        self.collectionType = nil
        self.childCount = nil
        self.localTrailerCount = nil
        self.specialFeatureCount = nil
        self.seriesPrimaryImageTag = nil
        self.providerIds = nil
        self.chapters = nil
        self.trickplay = nil
        self.albumArtist = nil
        self.artists = nil
        self.albumId = nil
        self.albumPrimaryImageTag = nil
    }

    /// Live-channel item so PlayerViewModel works unchanged for live playback; display name prefers the current program's title.
    init(liveChannel channel: JellyfinChannel, program: JellyfinProgram?) {
        self.id = channel.id
        // Sodalite#104: an EPG entry for an episode carries everything a stored one does, and these
        // three were hard-coded to nil, which is the only reason the player's title overlay showed
        // one line on live where a recording of the same episode shows two. `name` becomes the
        // EPISODE title when the guide names one, so the overlay's existing series branch renders a
        // live episode identically to a stored one.
        self.name = program?.episodeTitle ?? program?.name ?? channel.name
        self.sortName = nil
        self.originalTitle = nil
        self.overview = program?.overview
        self.type = .tvChannel
        // Sodalite#159: the header slot, which is what the guide puts above the episode line. With
        // only `SeriesName` in it, an EPG entry that names a programme and an episode but no series
        // (NOVA, and every sports broadcast) lost the programme name entirely: `name` above has
        // already been overwritten with the episode title, and the `?? program?.name` fallback
        // there is unreachable in exactly that case.
        // A movie keeps no header of its own, so it takes the branch a stored movie does: its name
        // over its year.
        let isMovie = program?.isMovie == true
        self.seriesName = isMovie ? program?.seriesName : program?.seriesName ?? program?.name
        self.seriesId = nil
        self.seasonId = nil
        // Both halves or neither: a lone "S4" beside a programme name identifies nothing, and the
        // guide already refuses to draw one (`EpisodeMetadataFormatter.programLabel`).
        self.parentIndexNumber = program?.indexNumber == nil ? nil : program?.parentIndexNumber
        self.indexNumber = program?.parentIndexNumber == nil ? nil : program?.indexNumber
        self.productionYear = program?.movieYear
        self.communityRating = nil
        self.criticRating = nil
        self.officialRating = nil
        self.runTimeTicks = nil
        self.premiereDate = nil
        self.endDate = nil
        self.status = nil
        self.genres = program?.genres
        self.taglines = nil
        self.imageTags = nil
        self.backdropImageTags = nil
        self.parentBackdropImageTags = nil
        self.userData = nil
        self.mediaStreams = nil
        self.mediaSources = nil
        self.people = nil
        self.studios = nil
        self.collectionType = nil
        self.childCount = nil
        self.localTrailerCount = nil
        self.specialFeatureCount = nil
        self.seriesPrimaryImageTag = nil
        self.providerIds = nil
        self.chapters = nil
        self.trickplay = nil
        self.albumArtist = nil
        self.artists = nil
        self.albumId = nil
        self.albumPrimaryImageTag = nil
    }

    /// Jellyfin's `MaxResumePct` default: past it the server counts the item as watched and stores no
    /// resume position at all.
    static let playedThresholdPercent: Double = 90

    /// Patch resume position in place after playback stops (issue #24): sets ticks + recomputes playedPercentage, no server round-trip. Creates userData if none.
    mutating func setResumePosition(_ ticks: Int64) {
        // Only a percentage computed from THIS stop may decide "watched": with no runtime the fallback
        // is the server's last percentage, and a stale 95% would drop a fresh position on the floor.
        let computed: Double? = {
            guard let total = runTimeTicks, total > 0 else { return nil }
            return min(100, max(0, Double(ticks) / Double(total) * 100))
        }()
        let pct = computed ?? userData?.playedPercentage
        let base = userData ?? UserItemData(
            playbackPositionTicks: nil, playCount: nil, isFavorite: nil,
            played: nil, unplayedItemCount: nil, playedPercentage: nil,
            lastPlayedDate: nil
        )
        // Past the threshold the server records "watched, no resume". Writing the raw end position
        // instead left the play button offering to resume the episode that had just finished, and the
        // detail view re-applies this patch after refreshing from the server, so the stale position
        // won the reconciliation (Sodalite#67).
        if let computed, computed >= Self.playedThresholdPercent {
            userData = base.with(playbackPositionTicks: 0, playedPercentage: 100, played: true)
            return
        }
        userData = base.with(playbackPositionTicks: ticks, playedPercentage: pct)
    }

    /// Fill in the fields only `detailFields` carries, from a detail fetch of the same item.
    ///
    /// Additive, never overwriting: the launch item's `userData` holds the resume position this
    /// session is already playing from, and a wholesale swap would replace it with the server's
    /// staler copy. `nil` is the only gap it closes, so `chapters == []` (the server answering
    /// "this file has none") survives.
    mutating func applyDetailFields(from detail: JellyfinItem) {
        // An auto-advance swaps the player's item while the previous episode's fetch is still in
        // flight, so a detail that names another item is not ours to apply.
        guard detail.id == id else { return }
        if chapters == nil { chapters = detail.chapters }
        if trickplay == nil { trickplay = detail.trickplay }
    }

    // `==` is deliberately the synthesized structural one, NOT `lhs.id == rhs.id`. An id-only `==`
    // makes every enrichment of an already-loaded item invisible: SwiftUI skips the invalidation for
    // an Equatable @State whose new value compares equal, so swapping a slim episode for its detailed
    // twin (same id, now with MediaStreams) wrote the storage but never re-ran body. The tech-info
    // strip then stayed hidden until some unrelated state change forced a render, which is why tvOS
    // seemed fine (its post-menu focus bounce is that unrelated change) and iOS did not.
    //
    // Hashing stays id-only: it is the cheap bucket, and the Hashable contract only requires equal
    // values to hash equally, which holds because structural equality implies equal ids.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Identity across servers: two servers can, in principle, mint the same id.
    var originKey: String { "\(serverID ?? "")|\(id)" }
}

enum ItemType: String, Codable, Sendable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case musicAlbum = "MusicAlbum"
    case audio = "Audio"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case folder = "Folder"
    case playlist = "Playlist"
    case tvChannel = "TvChannel"
    /// A file in a home-video library (and an extra); Jellyfin gives it no richer type (Sodalite#180).
    case video = "Video"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ItemType(rawValue: rawValue) ?? .unknown
    }
}

/// Chapter marker (from MKV/MP4 container or a tagger). `imageTag` is set only when the server generated a chapter thumbnail.
struct ChapterInfo: Codable, Sendable, Equatable, Hashable {
    let startPositionTicks: Int64
    let name: String?
    let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }

    /// Start in seconds (10⁷ ticks/sec).
    var startSeconds: Double {
        Double(startPositionTicks) / 10_000_000
    }
}

/// One trickplay rendition (Jellyfin 10.9+ Trickplay API). A tile image is a sprite of
/// `tileWidth` x `tileHeight` thumbnails, each `width` x `height`; `interval` is the ms between
/// thumbnails. Present only when the server admin enabled Trickplay generation and the task ran.
struct TrickplayInfo: Codable, Sendable, Equatable, Hashable {
    let width: Int
    let height: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailCount: Int
    let interval: Int
    let bandwidth: Int?

    enum CodingKeys: String, CodingKey {
        case width = "Width"
        case height = "Height"
        case tileWidth = "TileWidth"
        case tileHeight = "TileHeight"
        case thumbnailCount = "ThumbnailCount"
        case interval = "Interval"
        case bandwidth = "Bandwidth"
    }
}

struct ImageTags: Codable, Sendable, Equatable {
    let primary: String?
    let backdrop: String?
    let thumb: String?
    let logo: String?
    let banner: String?

    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case backdrop = "Backdrop"
        case thumb = "Thumb"
        case logo = "Logo"
        case banner = "Banner"
    }
}

struct UserItemData: Codable, Sendable, Equatable {
    let playbackPositionTicks: Int64?
    let playCount: Int?
    let isFavorite: Bool?
    let played: Bool?
    let unplayedItemCount: Int?
    let playedPercentage: Double?
    /// ISO-8601 last-play timestamp; kept raw (model convention) and unparsed (recency ordering is server-side via SortBy=DatePlayed).
    let lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case unplayedItemCount = "UnplayedItemCount"
        case playedPercentage = "PlayedPercentage"
        case lastPlayedDate = "LastPlayedDate"
    }

    /// Copy with resume position (and, if known, played percentage) replaced; in-memory patch after playback stops (issue #24). `played` defaults to keep-current, the watched-threshold patch passes it.
    func with(playbackPositionTicks ticks: Int64, playedPercentage pct: Double?, played newPlayed: Bool? = nil) -> UserItemData {
        UserItemData(
            playbackPositionTicks: ticks,
            playCount: playCount,
            isFavorite: isFavorite,
            played: newPlayed ?? played,
            unplayedItemCount: unplayedItemCount,
            playedPercentage: pct,
            lastPlayedDate: lastPlayedDate
        )
    }
}

struct MediaStream: Codable, Sendable, Equatable, Identifiable {
    let index: Int
    let type: MediaStreamType
    let codec: String?
    let language: String?
    let displayTitle: String?
    let title: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isExternal: Bool?
    let height: Int?
    let width: Int?
    let channels: Int?
    let videoRange: String?
    let videoRangeType: String?
    let averageFrameRate: Double?
    let realFrameRate: Double?
    let profile: String?
    let bitRate: Int?
    let dvProfile: Int?

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case title = "Title"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case height = "Height"
        case width = "Width"
        case channels = "Channels"
        case videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType"
        case averageFrameRate = "AverageFrameRate"
        case realFrameRate = "RealFrameRate"
        case profile = "Profile"
        case bitRate = "BitRate"
        case dvProfile = "DvProfile"
    }
}

enum MediaStreamType: String, Codable, Sendable {
    case video = "Video"
    case audio = "Audio"
    case subtitle = "Subtitle"
    case embeddedImage = "EmbeddedImage"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MediaStreamType(rawValue: rawValue) ?? .unknown
    }
}

struct MediaSource: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let mediaStreams: [MediaStream]?

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
        case mediaStreams = "MediaStreams"
    }
}

extension JellyfinItem {
    /// The `MediaSource` actually playing, resolved from the engine-picked id (`PlayerViewModel.mediaSourceID`).
    /// Multi-version items carry several `mediaSources`; consumers that show per-version detail (Stats overlay,
    /// issue #37) must reflect the picked version, not the primary/first one. Falls back to the first source when
    /// the id is nil, empty, or unmatched.
    func effectiveMediaSource(id sourceID: String?) -> MediaSource? {
        guard let sources = mediaSources, !sources.isEmpty else { return nil }
        if let sourceID, !sourceID.isEmpty,
           let match = sources.first(where: { $0.id == sourceID }) {
            return match
        }
        return sources.first
    }

    /// Container `MediaStream`s for the playing version. Falls back to the item-level `mediaStreams` (which mirror
    /// the primary source) when the matched source carries none.
    func effectiveMediaStreams(id sourceID: String?) -> [MediaStream]? {
        effectiveMediaSource(id: sourceID)?.mediaStreams ?? mediaStreams
    }
}

struct PersonInfo: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let role: String?
    let type: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct StudioInfo: Codable, Sendable, Equatable {
    let id: String?
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

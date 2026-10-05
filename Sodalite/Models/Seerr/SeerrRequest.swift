import Foundation

struct SeerrRequest: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let status: SeerrRequestStatus
    let createdAt: String?
    let updatedAt: String?
    let type: SeerrMediaType
    let is4k: Bool?
    let media: SeerrRequestMedia?
    let seasons: [SeerrRequestSeason]?
    let requestedBy: SeerrUser?
    /// The request's own Radarr/Sonarr routing. nil means "Seerr's default", which an edit has to send back
    /// as nil: the PUT assigns these fields rather than merging them.
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?
    /// nil and [] differ on the server ([] is stored as "none", an explicit no-tags choice).
    let tags: [Int]?

    /// Still in the pipeline as far as Jellyseerr is concerned. Declined, failed and completed requests are history: they keep their stale season entries forever (Jellyseerr never reverts them), so anything reading a pipeline state has to gate on this.
    var isOpen: Bool {
        status == .pendingApproval || status == .approved
    }
}

struct SeerrRequestMedia: Codable, Sendable, Equatable {
    let id: Int?
    let tmdbId: Int?
    let mediaType: SeerrMediaType?
    let status: SeerrMediaStatus?
    /// Sonarr/Radarr server id the media is attached to.
    let serviceId: Int?
    /// Written by Jellyseerr's library scan; absent on Overseerr and on unmatched titles.
    let jellyfinMediaId: String?
}

struct SeerrRequestSeason: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let seasonNumber: Int
    /// Request axis (MediaRequestStatus), NOT the MediaStatus that `SeerrMediaSeason.status` carries. The two overlap numerically (2 is APPROVED here, PENDING there), so decoding this as SeerrMediaStatus made every auto-approved season read as "waiting for approval".
    let status: SeerrRequestStatus?
}

struct SeerrCreateRequestBody: Encodable, Sendable {
    let mediaType: SeerrMediaType
    let mediaId: Int
    let seasons: [Int]?
    let serverId: Int?
    let profileId: Int?
    let rootFolder: String?
    let languageProfileId: Int?
    /// Sonarr/Radarr tag ids for the download; send nil (not []) for "no tags" to stay compatible with older Jellyseerr that lacks the field.
    let tags: [Int]?

    init(
        mediaType: SeerrMediaType,
        mediaId: Int,
        seasons: [Int]? = nil,
        serverId: Int? = nil,
        profileId: Int? = nil,
        rootFolder: String? = nil,
        languageProfileId: Int? = nil,
        tags: [Int]? = nil
    ) {
        self.mediaType = mediaType
        self.mediaId = mediaId
        self.seasons = seasons
        self.serverId = serverId
        self.profileId = profileId
        self.rootFolder = rootFolder
        self.languageProfileId = languageProfileId
        self.tags = tags
    }
}

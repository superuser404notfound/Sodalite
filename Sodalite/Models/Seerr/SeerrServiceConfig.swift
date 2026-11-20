import Foundation

/// A Radarr/Sonarr instance from `/service/radarr|sonarr`; `isDefault` marks the one used when the request body omits `serverId`.
struct SeerrServiceServer: Codable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let isDefault: Bool?
    let is4k: Bool?
    let activeProfileId: Int?
    let activeDirectory: String?
    let activeLanguageProfileId: Int?
    /// The tags Seerr puts on every request to this instance. A request's own tags replace them, and an
    /// empty list is stored as none, so it cannot take them away.
    var activeTags: [Int]? = nil
}

struct SeerrServiceDetails: Codable, Sendable {
    let server: SeerrServiceServer
    let profiles: [SeerrQualityProfile]
    let rootFolders: [SeerrRootFolder]
    let languageProfiles: [SeerrLanguageProfile]?
    /// Sonarr/Radarr tag list (forwarded from `/api/v3/tag`) for attaching tag ids to the download.
    let tags: [SeerrTag]?
}

struct SeerrTag: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let label: String
}

struct SeerrQualityProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
}

struct SeerrRootFolder: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let path: String
    let freeSpace: Int64?
}

struct SeerrLanguageProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
}

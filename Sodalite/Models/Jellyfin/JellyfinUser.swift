import Foundation

struct JellyfinUser: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let serverID: String
    let hasPassword: Bool?
    let primaryImageTag: String?
    /// Server-side policy; omitted by sparse responses (`/Users/Public`), populated by `/Users/Me` and `/Users/{id}`.
    let policy: Policy?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
        case hasPassword = "HasPassword"
        case primaryImageTag = "PrimaryImageTag"
        case policy = "Policy"
    }

    struct Policy: Codable, Sendable, Equatable {
        let isAdministrator: Bool
        let enableContentDeletion: Bool
        /// Optional with a default so older persisted copies and the hand-written inits stay valid; nil
        /// reads as "not granted" / "restricted" wherever a gate consults it.
        var enableLiveTvManagement: Bool? = nil
        var enableAllFolders: Bool? = nil
        var maxParentalRating: Int? = nil
        var blockedTags: [String]? = nil
        var allowedTags: [String]? = nil
        var blockUnratedItems: [String]? = nil
        var enableVideoPlaybackTranscoding: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case isAdministrator = "IsAdministrator"
            case enableContentDeletion = "EnableContentDeletion"
            case enableLiveTvManagement = "EnableLiveTvManagement"
            case enableAllFolders = "EnableAllFolders"
            case maxParentalRating = "MaxParentalRating"
            case blockedTags = "BlockedTags"
            case allowedTags = "AllowedTags"
            case blockUnratedItems = "BlockUnratedItems"
            case enableVideoPlaybackTranscoding = "EnableVideoPlaybackTranscoding"
        }

        /// Every field is optional on the wire: a server that omits one (seen in TestFlight feedback for
        /// `EnableContentDeletion`) must not fail the whole login decode. A missing grant reads as not granted.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isAdministrator = try c.decodeIfPresent(Bool.self, forKey: .isAdministrator) ?? false
            enableContentDeletion = try c.decodeIfPresent(Bool.self, forKey: .enableContentDeletion) ?? false
            enableLiveTvManagement = try c.decodeIfPresent(Bool.self, forKey: .enableLiveTvManagement)
            enableAllFolders = try c.decodeIfPresent(Bool.self, forKey: .enableAllFolders)
            maxParentalRating = try c.decodeIfPresent(Int.self, forKey: .maxParentalRating)
            blockedTags = try c.decodeIfPresent([String].self, forKey: .blockedTags)
            allowedTags = try c.decodeIfPresent([String].self, forKey: .allowedTags)
            blockUnratedItems = try c.decodeIfPresent([String].self, forKey: .blockUnratedItems)
            enableVideoPlaybackTranscoding = try c.decodeIfPresent(Bool.self, forKey: .enableVideoPlaybackTranscoding)
        }
    }

    /// Admin (implicit all-rights) or EnableContentDeletion. False when `policy` is unloaded (conservative default pre first getCurrentUser()).
    var canDeleteContent: Bool {
        guard let policy = policy else { return false }
        return policy.isAdministrator || policy.enableContentDeletion
    }

    /// Jellyfin's `EnableLiveTvManagement`, which every timer and series-timer endpoint checks with no
    /// administrator shortcut. False while the policy is unloaded, like `canDeleteContent`.
    var canManageLiveTv: Bool {
        policy?.enableLiveTvManagement == true
    }

    /// Jellyfin's `EnableVideoPlaybackTranscoding`. Without it the server still hands out a transcode
    /// URL for a capped request, but copies the video, so no bitrate cap is ever applied (Sodalite#202).
    /// True while the policy is unloaded: that is the server default, and the rungs were offered before.
    var canTranscodeVideo: Bool {
        policy?.enableVideoPlaybackTranscoding != false
    }

    /// Nothing in the policy keeps library items from this user: every folder, no rating ceiling, no tag
    /// filter. Jellyfin answers 404 for an item the user may not see exactly as for one that is gone, so
    /// only for this user does a 404 on a known item id prove the item was deleted.
    var seesWholeLibrary: Bool {
        guard let policy else { return false }
        return policy.enableAllFolders == true
            && policy.maxParentalRating == nil
            && (policy.blockedTags ?? []).isEmpty
            && (policy.allowedTags ?? []).isEmpty
            && (policy.blockUnratedItems ?? []).isEmpty
    }
}

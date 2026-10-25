import SwiftUI

enum SeerrMediaStatus: Int, Codable, Sendable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    /// The server's own DELETED. Jellyseerr stamps it on the media AND every season when `DELETE /media/{id}/file` removes the title from Radarr/Sonarr, which is exactly what Sodalite's delete flow calls. Decoding it as `.unknown` made the season fall through to the still-approved request and read as "downloading" forever. Doubles as the sentinel the Jellyfin ground-truth reconcile writes when a Seerr-"available" title is absent from the library. BLOCKLISTED (6) stays `.unknown`, it is a state of its own and no UI shows it.
    case deleted = 7
    /// Client-only, the server has no such value. Jellyseerr leaves the media on PROCESSING when the Radarr/Sonarr handover fails and marks only the request FAILED, so `SeerrSeasonStatusResolver` writes this when a failed request is all that is left behind the pipeline state (Sodalite#210).
    case failed = 1000

    // Lenient decode: newer Seerr may add states; an unknown int would abort the whole /movie|/tv decode, so fall back to `.unknown`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        // `.failed` is the client's own verdict, never something the server can say.
        self = raw == Self.failed.rawValue ? .unknown : SeerrMediaStatus(rawValue: raw) ?? .unknown
    }

    var localizationKey: String {
        switch self {
        case .unknown: "catalog.status.unknown"
        case .pending: "catalog.status.pending"
        case .processing: "catalog.status.processing"
        case .partiallyAvailable: "catalog.status.partiallyAvailable"
        case .available: "catalog.status.available"
        case .deleted: "catalog.status.removed"
        case .failed: "catalog.requestStatus.failed"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .pending: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .available: "checkmark.circle.fill"
        case .deleted: "trash"
        case .failed: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .gray
        case .pending: .orange
        case .processing: .blue
        case .partiallyAvailable: .teal
        case .available: .green
        case .deleted: .gray
        case .failed: .red
        }
    }
}

enum SeerrRequestStatus: Int, Codable, Sendable {
    case pendingApproval = 1
    case approved = 2
    case declined = 3
    case failed = 4
    case completed = 5

    // Lenient (as SeerrMediaStatus): `completed = 5` is returned for requests on already-available items, so without it any owned library item failed to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self = SeerrRequestStatus(rawValue: raw) ?? .pendingApproval
    }

    var localizationKey: String {
        switch self {
        case .pendingApproval: "catalog.requestStatus.pending"
        case .approved: "catalog.requestStatus.approved"
        case .declined: "catalog.requestStatus.declined"
        case .failed: "catalog.requestStatus.failed"
        case .completed: "catalog.requestStatus.completed"
        }
    }
}

enum SeerrMediaType: String, Codable, Sendable {
    case movie
    case tv
    // `/search` returns `person` too; decoded so the array parse succeeds, filtered out in the service layer before UI.
    case person
    // Lenient fallback: mediaType is non-optional on SeerrMedia, so an unrecognized string would abort the whole discover/search array decode. Inert, filtered like `person`.
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SeerrMediaType(rawValue: raw) ?? .unknown
    }
}

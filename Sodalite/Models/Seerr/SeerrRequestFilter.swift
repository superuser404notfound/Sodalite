import Foundation

/// Status filter for `GET /api/v1/request`; raw values are the literal query-string values (verified against request.ts mapStatusToTypes). `.all` is the default no-filter case.
enum SeerrRequestFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case pending  = "pending"
    case approved = "approved"
    case declined = "declined"
    case all      = "all"

    var id: String { rawValue }
}

enum SeerrRequestSort: String, Sendable {
    case added
    case modified
}

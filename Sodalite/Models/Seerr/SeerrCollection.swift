import Foundation

/// `/api/v1/collection/{id}`: a TMDB movie collection with its parts, release-date sorted by the server.
/// `parts` runs through Jellyseerr's own `mapMovieResult`, so every entry carries `mediaType` and the same
/// `mediaInfo` the discover rows use; the availability badge on each card needs no extra lookup.
struct SeerrCollection: Codable, Sendable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let parts: [SeerrMedia]?
}

/// The `collection` stub `/movie/{id}` already carries: enough to label and open the entry point without a
/// second request. Only the collection endpoint returns the parts. TV has no equivalent, TMDB collections are
/// a movie-only concept.
struct SeerrCollectionRef: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let posterPath: String?
    let backdropPath: String?
}

enum SeerrCollectionRequestPlan {
    /// The parts a bulk request should actually post. `.pending`/`.processing` are already requested and
    /// `.available`/`.partiallyAvailable` are already on the server, so re-requesting either would only earn a 202
    /// from Seerr. `.deleted` and `.failed` are deliberately included: a removed or failed title has to stay re-requestable.
    static func missingParts(in parts: [SeerrMedia]) -> [SeerrMedia] {
        parts.filter { part in
            switch part.mediaInfo?.displayStatus {
            case .none, .unknown, .deleted, .failed: true
            case .pending, .processing, .partiallyAvailable, .available: false
            }
        }
    }
}

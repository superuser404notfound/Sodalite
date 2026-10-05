import Foundation

/// One of the user's own requests as the diff sees it: both status axes plus the requested seasons
/// already on the server.
struct MyRequestObservation: Equatable {
    let requestID: Int
    let requesterID: Int?
    let createdAt: Date?
    let mediaType: SeerrMediaType
    let tmdbID: Int?
    let jellyfinItemID: String?
    let requestStatus: SeerrRequestStatus
    let mediaStatus: SeerrMediaStatus?
    let requestedSeasons: [Int]
    let availableSeasons: Set<Int>
}

extension MyRequestObservation {
    init(request: SeerrRequest, availableSeasons: Set<Int>) {
        self.init(
            requestID: request.id,
            requesterID: request.requestedBy?.id,
            createdAt: request.createdAt.flatMap(SeerrDate.parse),
            mediaType: request.type,
            tmdbID: request.media?.tmdbId,
            jellyfinItemID: request.media?.jellyfinMediaId,
            requestStatus: request.status,
            mediaStatus: request.media?.status,
            requestedSeasons: (request.seasons ?? []).map(\.seasonNumber).sorted(),
            availableSeasons: availableSeasons
        )
    }
}

enum SeerrDate {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// Last seen state of the user's own requests. Raw integers, so a lenient enum fallback can never
/// rewrite what was recorded.
struct MyRequestsSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var requestStatus: Int
        var mediaStatus: Int?
        var availableSeasons: Set<Int>
    }

    var baselineDate: Date
    var entries: [Int: Entry]
}

struct MyRequestEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case approved, declined, failed, available
    }

    let requestID: Int
    let kind: Kind
    let mediaType: SeerrMediaType
    let tmdbID: Int?
    var seasons: [Int]
    var jellyfinItemID: String?
    var title: String?
    var posterPath: String?
    let date: Date

    var id: String { "\(requestID)-\(kind.rawValue)" }

    static func merging(_ new: [MyRequestEvent], into existing: [MyRequestEvent]) -> [MyRequestEvent] {
        var result = existing
        for event in new {
            guard let index = result.firstIndex(where: { $0.id == event.id }) else {
                result.append(event)
                continue
            }
            var merged = event
            merged.seasons = Array(Set(result[index].seasons).union(event.seasons)).sorted()
            merged.jellyfinItemID = event.jellyfinItemID ?? result[index].jellyfinItemID
            merged.title = event.title ?? result[index].title
            merged.posterPath = event.posterPath ?? result[index].posterPath
            result[index] = merged
        }
        return result
    }
}

import Foundation

/// Keeps a catalog row to what the server does NOT have.
///
/// Two independent nets, because each one alone leaves a hole: Jellyseerr's own library sync answers
/// for the whole library but can be stale or unconfigured, while the key match answers only against
/// the Jellyfin items actually in hand (a search result set, a similar-titles row) and is always current.
enum SeerrLibraryDedupe {
    /// Drop what Jellyseerr already reports as on the server. `.pending`/`.processing` stay: those are
    /// requested but not there yet, and their badge is what stops a second request.
    static func droppingAvailable(_ media: [SeerrMedia]) -> [SeerrMedia] {
        media.filter { !$0.isOnServer }
    }

    /// What Jellyseerr suggests next to a title and the server does not have: its recommendations,
    /// else its similar titles. The fallback runs when recommendations fail, are empty, or are all
    /// owned, so one failing endpoint does not hide the row. Shared by the catalog and the detail page,
    /// which had two copies that already disagreed on a failure (audit CAT-R201).
    static func suggestions(
        service: SeerrMediaServiceProtocol, mediaType: SeerrMediaType, tmdbID: Int
    ) async -> [SeerrMedia] {
        let recommended = (try? await service.recommendations(mediaType: mediaType, tmdbID: tmdbID)) ?? []
        let candidates = droppingAvailable(recommended)
        if !candidates.isEmpty { return candidates }
        let similar = (try? await service.similar(mediaType: mediaType, tmdbID: tmdbID)) ?? []
        return droppingAvailable(similar)
    }

    /// Remove Seerr entries that match one of the given Jellyfin items. Both keys are qualified by media
    /// type: TMDB reuses numeric ids across the movie and tv namespaces (mirrors SeerrMedia.stableKey),
    /// so an owned movie must not suppress a different series sharing that id (or the same title+year).
    /// Primary key: type + TMDB id; fallback (no TMDB provider id, e.g. manual imports/old scanner):
    /// type + normalized title + production year.
    static func removing(_ media: [SeerrMedia], matching jellyfin: [JellyfinItem]) -> [SeerrMedia] {
        var jellyfinTmdbKeys: Set<String> = []
        var jellyfinTitleYears: Set<String> = []
        for item in jellyfin {
            guard let type = seerrType(item.type) else { continue }
            if let tmdb = item.tmdbID { jellyfinTmdbKeys.insert("\(type)-\(tmdb)") }
            jellyfinTitleYears.insert("\(type)|" + titleYearKey(name: item.name, year: item.productionYear))
        }

        return media.filter { media in
            let type = media.mediaType.rawValue
            if jellyfinTmdbKeys.contains("\(type)-\(media.id)") { return false }
            let mediaYear = Int(media.displayYear ?? "")
            let key = "\(type)|" + titleYearKey(name: media.displayTitle, year: mediaYear)
            return !jellyfinTitleYears.contains(key)
        }
    }

    private static func seerrType(_ type: ItemType) -> String? {
        switch type {
        case .movie: return SeerrMediaType.movie.rawValue
        case .series: return SeerrMediaType.tv.rawValue
        default: return nil
        }
    }

    private static func titleYearKey(name: String, year: Int?) -> String {
        let normalized = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        return "\(normalized)|\(year ?? 0)"
    }
}

extension SeerrMedia {
    /// The server already holds this title, whole or in part, as Jellyseerr's library sync reports it.
    ///
    /// Media axis, not the request axis: this reads `mediaInfo.status` on a Media entity, where the same
    /// integers mean something else than on a request (see SeerrMediaStatus). `.partiallyAvailable` counts
    /// as owned, that is the normal state of a running series someone is watching.
    var isOnServer: Bool {
        switch mediaInfo?.status {
        case .available, .partiallyAvailable: true
        case .none, .unknown, .pending, .processing, .deleted, .failed: false
        }
    }
}

import Foundation

/// The physically next episode, deliberately NOT Jellyfin's NextUp: NextUp returns the next
/// UNWATCHED episode series-wide and skips partly watched seasons (S1E5 -> S3E1 over a partial S2).
/// The player's auto-advance and the episode page's advance after a finished episode (Sodalite#230)
/// both mean the episode that comes next on the disc, so they share this rule.
///
/// Date-based shows (talk shows, news, dailies) often reach Jellyfin with an air date and no episode
/// number. An episode without an index is placed by its air date instead, so auto-advance works there
/// too; before, it found no successor and the player closed back to the list.
enum EpisodeSuccession {
    /// The episode that follows `episode` in its own season's list: the lowest later index, or for an
    /// episode without one, the earliest later air date.
    static func next(after episode: JellyfinItem, in seasonEpisodes: [JellyfinItem]) -> JellyfinItem? {
        let others = seasonEpisodes.filter { $0.id != episode.id }
        if let index = episode.indexNumber {
            return others
                .filter { ($0.indexNumber ?? -1) > index }
                .min { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
        }
        guard let key = DatedKey(episode) else { return nil }
        return others
            .compactMap { candidate in DatedKey(candidate).map { (candidate, $0) } }
            .filter { $0.1 > key }
            .min { $0.1 < $1.1 }?.0
    }

    /// The season after `seasonID` by index. Strictly greater skips Specials (season 0), so a finale
    /// advances to S2E1 and not into the specials.
    static func season(after seasonID: String, in seasons: [JellyfinItem]) -> JellyfinItem? {
        guard let current = seasons.first(where: { $0.id == seasonID })?.indexNumber else { return nil }
        return seasons
            .filter { ($0.indexNumber ?? -1) > current }
            .min { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
    }

    /// Where a season starts.
    static func first(in seasonEpisodes: [JellyfinItem]) -> JellyfinItem? {
        seasonEpisodes.min(by: inDiscOrder)
    }

    /// Index first, then air date, then name. Numbered episodes keep their old order, and a season of
    /// dated ones reads oldest first instead of in whatever order an unstable sort left them.
    static func inDiscOrder(_ lhs: JellyfinItem, _ rhs: JellyfinItem) -> Bool {
        let l = (lhs.indexNumber ?? .max, airDate(lhs) ?? .distantFuture, lhs.sortName ?? lhs.name, lhs.id)
        let r = (rhs.indexNumber ?? .max, airDate(rhs) ?? .distantFuture, rhs.sortName ?? rhs.name, rhs.id)
        return l < r
    }

    private static func airDate(_ episode: JellyfinItem) -> Date? {
        episode.premiereDate.flatMap(ISODateParser.parse)
    }

    /// Two episodes on the same day (a morning and an evening edition) fall back to the name, and the
    /// id keeps the order total.
    private struct DatedKey: Comparable {
        let date: Date
        let name: String
        let id: String

        init?(_ episode: JellyfinItem) {
            guard let date = EpisodeSuccession.airDate(episode) else { return nil }
            self.date = date
            name = episode.sortName ?? episode.name
            id = episode.id
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.date, lhs.name, lhs.id) < (rhs.date, rhs.name, rhs.id)
        }
    }
}

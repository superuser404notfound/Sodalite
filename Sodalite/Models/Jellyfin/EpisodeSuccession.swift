import Foundation

/// The physically next episode, deliberately NOT Jellyfin's NextUp: NextUp returns the next
/// UNWATCHED episode series-wide and skips partly watched seasons (S1E5 -> S3E1 over a partial S2).
/// The player's auto-advance and the episode page's advance after a finished episode (Sodalite#230)
/// both mean the episode that comes next on the disc, so they share this rule.
enum EpisodeSuccession {
    /// The lowest index strictly after `episode` in its own season's list.
    static func next(after episode: JellyfinItem, in seasonEpisodes: [JellyfinItem]) -> JellyfinItem? {
        guard let index = episode.indexNumber else { return nil }
        return seasonEpisodes
            .filter { $0.id != episode.id && ($0.indexNumber ?? -1) > index }
            .min { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
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
        seasonEpisodes.min { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
    }
}

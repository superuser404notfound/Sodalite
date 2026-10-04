import Foundation

/// Combines one Home row fetched from several servers into the row a combined Home shows
/// (Sodalite#85). Pure: lists in, list out. `lists` arrive in source priority order, active first.
nonisolated enum HomeMerger {
    enum Order: Equatable {
        case lastPlayedDescending, roundRobin, resumeThenRoundRobin, dateCreatedDescending
        case premiereDescending, ratingDescending, sortNameAscending, episodeOrder
    }

    static func order(for type: HomeRowType, mergedContinueWatching: Bool) -> Order {
        switch type {
        case .continueWatching: mergedContinueWatching ? .resumeThenRoundRobin : .lastPlayedDescending
        case .latestMovies, .recentlyAdded: .dateCreatedDescending
        case .recentlyReleasedMovies: .premiereDescending
        case .topRatedMovies, .topRatedShows: .ratingDescending
        case .allMovies, .allSeries, .favorites, .collections, .playlists: .sortNameAscending
        case .favoriteEpisodes: .episodeOrder
        // Folded rows carry the series' own dates, so a date sort would invent an order.
        case .nextUp, .latestShows, .recentlyReleasedShows, .libraryLatest,
             .myMedia, .genres, .discoverProviders: .roundRobin
        }
    }

    /// The row's own query limit, so a merged row is as long as a single-server one can be.
    static func limit(for type: HomeRowType, mergedContinueWatching: Bool) -> Int {
        switch type {
        case .continueWatching: mergedContinueWatching ? 32 : 16
        case .nextUp, .latestMovies, .latestShows, .recentlyReleasedShows, .libraryLatest: 16
        case .recentlyReleasedMovies, .recentlyAdded, .topRatedMovies, .topRatedShows: 20
        case .allMovies, .allSeries, .favorites, .favoriteEpisodes, .collections, .playlists: 30
        case .myMedia, .genres, .discoverProviders: 30
        }
    }

    static func dedupes(_ type: HomeRowType) -> Bool {
        type != .collections && type != .playlists
    }

    /// Same title on two servers: type plus the first provider id it carries.
    static func dedupeKey(_ item: JellyfinItem) -> String? {
        for provider in ["Tmdb", "Imdb", "Tvdb"] {
            if let value = item.providerIds?.first(where: { $0.key.caseInsensitiveCompare(provider) == .orderedSame })?.value,
               !value.isEmpty {
                return "\(item.type.rawValue):\(provider.lowercased()):\(value)"
            }
        }
        return nil
    }

    /// `limit` overrides the row's own, for a grid that merges a whole list.
    static func merge(_ lists: [[JellyfinItem]], type: HomeRowType, mergedContinueWatching: Bool, limit: Int? = nil) -> [JellyfinItem] {
        guard lists.count > 1 else { return lists.first ?? [] }
        let limit = limit ?? Self.limit(for: type, mergedContinueWatching: mergedContinueWatching)
        let order = order(for: type, mergedContinueWatching: mergedContinueWatching)
        let ordered = arrange(lists, order: order)
        let result = dedupes(type) ? deduplicate(ordered, newestWins: order == .lastPlayedDescending) : ordered
        return Array(result.map(\.item).prefix(limit))
    }

    private struct Entry {
        let item: JellyfinItem
        let source: Int
        let position: Int
    }

    private static func arrange(_ lists: [[JellyfinItem]], order: Order) -> [Entry] {
        let entries = lists.enumerated().flatMap { source, list in
            list.enumerated().map { Entry(item: $1, source: source, position: $0) }
        }
        switch order {
        case .roundRobin:
            return roundRobin(entries)
        case .resumeThenRoundRobin:
            let resume = entries.filter { ($0.item.userData?.playbackPositionTicks ?? 0) > 0 }
            let rest = entries.filter { ($0.item.userData?.playbackPositionTicks ?? 0) <= 0 }
            return stableSort(resume) { descending($0.item.userData?.lastPlayedDate, $1.item.userData?.lastPlayedDate) }
                + roundRobin(rest)
        case .lastPlayedDescending:
            return stableSort(entries) { descending($0.item.userData?.lastPlayedDate, $1.item.userData?.lastPlayedDate) }
        case .dateCreatedDescending:
            return stableSort(entries) { descending($0.item.dateCreated, $1.item.dateCreated) }
        case .premiereDescending:
            return stableSort(entries) { descending($0.item.premiereDate, $1.item.premiereDate) }
        case .ratingDescending:
            return stableSort(entries) {
                switch ($0.item.communityRating, $1.item.communityRating) {
                case let (l?, r?): l == r ? nil : l > r
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): nil
                }
            }
        case .sortNameAscending:
            return stableSort(entries) { lhs, rhs in
                let result = (lhs.item.sortName ?? lhs.item.name).localizedStandardCompare(rhs.item.sortName ?? rhs.item.name)
                return result == .orderedSame ? nil : result == .orderedAscending
            }
        case .episodeOrder:
            return stableSort(entries) { lhs, rhs in
                let l = (lhs.item.seriesName ?? "", lhs.item.parentIndexNumber ?? 0, lhs.item.indexNumber ?? 0)
                let r = (rhs.item.seriesName ?? "", rhs.item.parentIndexNumber ?? 0, rhs.item.indexNumber ?? 0)
                let byName = l.0.localizedStandardCompare(r.0)
                if byName != .orderedSame { return byName == .orderedAscending }
                if l.1 != r.1 { return l.1 < r.1 }
                if l.2 != r.2 { return l.2 < r.2 }
                return nil
            }
        }
    }

    private static func roundRobin(_ entries: [Entry]) -> [Entry] {
        entries.sorted { ($0.position, $0.source) < ($1.position, $1.source) }
    }

    /// `before` answers nil for a tie, which falls back to source then position, so equal keys keep
    /// the active server first and each server's own order.
    private static func stableSort(_ entries: [Entry], before: (Entry, Entry) -> Bool?) -> [Entry] {
        entries.sorted { lhs, rhs in
            if let decided = before(lhs, rhs) { return decided }
            return (lhs.source, lhs.position) < (rhs.source, rhs.position)
        }
    }

    /// ISO 8601 strings from one server family compare correctly as strings; nil sorts last.
    private static func descending(_ lhs: String?, _ rhs: String?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?): l == r ? nil : l > r
        case (.some, .none): true
        case (.none, .some): false
        case (.none, .none): nil
        }
    }

    /// One tile per title, at the rank of its first appearance. The copy shown is the one with
    /// progress, else the highest-priority server's; in a last-played timeline the newest wins.
    private static func deduplicate(_ entries: [Entry], newestWins: Bool) -> [Entry] {
        var winners: [String: Entry] = [:]
        for entry in entries {
            guard let key = dedupeKey(entry.item) else { continue }
            guard let current = winners[key] else { winners[key] = entry; continue }
            if newestWins { continue }
            let hasProgress = { (e: Entry) in (e.item.userData?.playbackPositionTicks ?? 0) > 0 }
            if hasProgress(entry) != hasProgress(current) {
                if hasProgress(entry) { winners[key] = entry }
            } else if entry.source < current.source {
                winners[key] = entry
            }
        }
        var emitted = Set<String>()
        return entries.compactMap { entry in
            guard let key = dedupeKey(entry.item) else { return entry }
            guard emitted.insert(key).inserted else { return nil }
            return winners[key]
        }
    }
}

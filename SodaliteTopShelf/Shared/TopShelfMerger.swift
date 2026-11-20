import Foundation

/// Merges the shelf's two rows across the servers of a combined Home (Sodalite#218), by the rules
/// `HomeMerger` applies to Home's rows of the same name, so the shelf and Home agree on order and on
/// which copy of a title they show. Its own type because the extension cannot see `JellyfinItem`;
/// `TopShelfMergerTests` holds the two to the same answers. `lists` arrive active server first.
nonisolated enum TopShelfMerger {
    /// Home's Continue Watching: newest played first, and of two copies the newer one.
    static func resume(_ lists: [[TopShelfItem]], limit: Int) -> [TopShelfItem] {
        guard lists.count > 1 else { return lists.first ?? [] }
        let ordered = stableSort(entries(lists)) {
            descending($0.item.userData?.lastPlayedDate, $1.item.userData?.lastPlayedDate)
        }
        return Array(deduplicate(ordered, newestWins: true).map(\.item).prefix(limit))
    }

    /// Home's Next Up: one from each server in turn, and of two copies the one with progress, else
    /// the active server's.
    static func nextUp(_ lists: [[TopShelfItem]], limit: Int) -> [TopShelfItem] {
        guard lists.count > 1 else { return lists.first ?? [] }
        let ordered = entries(lists).sorted { ($0.position, $0.source) < ($1.position, $1.source) }
        return Array(deduplicate(ordered, newestWins: false).map(\.item).prefix(limit))
    }

    /// Same title on two servers: type plus the first provider id it carries, as on Home.
    static func dedupeKey(_ item: TopShelfItem) -> String? {
        for provider in ["Tmdb", "Imdb", "Tvdb"] {
            if let value = item.providerIds?.first(where: { $0.key.caseInsensitiveCompare(provider) == .orderedSame })?.value,
               !value.isEmpty {
                return "\(item.type.rawValue):\(provider.lowercased()):\(value)"
            }
        }
        return nil
    }

    private struct Entry {
        let item: TopShelfItem
        let source: Int
        let position: Int
    }

    private static func entries(_ lists: [[TopShelfItem]]) -> [Entry] {
        lists.enumerated().flatMap { source, list in
            list.enumerated().map { Entry(item: $1, source: source, position: $0) }
        }
    }

    private static func stableSort(_ entries: [Entry], before: (Entry, Entry) -> Bool?) -> [Entry] {
        entries.sorted { lhs, rhs in
            if let decided = before(lhs, rhs) { return decided }
            return (lhs.source, lhs.position) < (rhs.source, rhs.position)
        }
    }

    private static func descending(_ lhs: String?, _ rhs: String?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?): l == r ? nil : l > r
        case (.some, .none): true
        case (.none, .some): false
        case (.none, .none): nil
        }
    }

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

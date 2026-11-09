import Foundation

/// DIAG(trakt-duplicates), temporary. Counts the plays the four seasonless syncs of 2026-11-09 put
/// into the tester's Trakt history, read-only, so the cleanup can be decided on numbers. Trakt does
/// not de-duplicate history adds, and those syncs pushed every Jellyfin-watched episode as unseen.
enum TraktDuplicateAudit {

    /// The pushes, from the device log (UTC). An add without `watched_at` was stamped "now".
    private static let pushWindows: [Date] = [
        "2026-11-09T19:05:33Z", "2026-11-09T19:13:36Z", "2026-11-09T19:32:18Z", "2026-11-09T19:48:06Z",
    ].compactMap { ISO8601DateFormatter().date(from: $0) }

    static func run(client: TraktClient, library: TraktLibrary) async {
        var entries: [TraktHistoryEntry] = []
        for page in 1...200 {
            guard let batch = try? await client.get(.episodeHistory(page: page), as: [TraktHistoryEntry].self) else {
                LogTap.shared.note("[Trakt] DIAG audit: page \(page) failed, stopping")
                break
            }
            entries += batch
            if batch.count < 250 { break }
        }

        // Jellyfin's last-played second per episode, under every key of its series.
        let seriesIDs = Dictionary(library.series.map { ($0.itemID, $0.ids) }, uniquingKeysWith: { a, _ in a })
        var jellyfinPlayed: [String: Int] = [:]
        for episode in library.episodes where episode.played {
            guard let ids = seriesIDs[episode.seriesID], let date = episode.lastPlayed else { continue }
            for key in TraktKey.keys(ids) {
                jellyfinPlayed[TraktKey.episode(showKey: key, season: episode.season, number: episode.number)] =
                    Int(date.timeIntervalSince1970)
            }
        }

        func episodeKeys(_ entry: TraktHistoryEntry) -> [String] {
            guard let show = entry.show, let season = entry.episode?.season, let number = entry.episode?.number
            else { return [] }
            return TraktKey.keys(show.ids).map { TraktKey.episode(showKey: $0, season: season, number: number) }
        }
        func inWindow(_ date: Date) -> Bool { pushWindows.contains { abs($0.timeIntervalSince(date)) < 90 } }
        func matchesJellyfin(_ entry: TraktHistoryEntry) -> Bool {
            let second = Int(entry.watchedAt.timeIntervalSince1970)
            return episodeKeys(entry).contains { key in jellyfinPlayed[key].map { abs($0 - second) <= 1 } ?? false }
        }
        func episodeID(_ entry: TraktHistoryEntry) -> String {
            entry.episode?.ids?.trakt.map(String.init) ?? episodeKeys(entry).first ?? "?"
        }

        var actions: [String: Int] = [:]
        for entry in entries { actions[entry.action, default: 0] += 1 }

        // R1, conservative: exact duplicates (same episode, same second) beyond the first, plus
        // "now"-stamped plays from a push window on an episode that has another play.
        var r1: Set<Int64> = []
        let groups = Dictionary(grouping: entries) { "\(episodeID($0))@\(Int($0.watchedAt.timeIntervalSince1970))" }
        for group in groups.values where group.count > 1 {
            for entry in group.sorted(by: { $0.id < $1.id }).dropFirst() { r1.insert(entry.id) }
        }
        let byEpisode = Dictionary(grouping: entries, by: episodeID)
        for plays in byEpisode.values where plays.count > 1 {
            for entry in plays where entry.action == "watch" && inWindow(entry.watchedAt) { r1.insert(entry.id) }
        }

        // R2, broader: every play that looks like one of ours (a "watch" at Jellyfin's exact time or
        // in a push window) when the episode has another play that does not, else all but one of ours.
        var r2: Set<Int64> = []
        for plays in byEpisode.values {
            let ours = plays.filter { $0.action == "watch" && (matchesJellyfin($0) || inWindow($0.watchedAt)) }
            let others = plays.count - ours.count
            let removable = others > 0 ? ours : Array(ours.sorted(by: { $0.id < $1.id }).dropFirst())
            for entry in removable { r2.insert(entry.id) }
        }

        func topShows(_ ids: Set<Int64>) -> String {
            let titles = entries.filter { ids.contains($0.id) }.map { $0.show?.title ?? "?" }
            return Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
                .sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }

        LogTap.shared.note("[Trakt] DIAG audit: \(entries.count) episode plays, actions \(actions), "
            + "\(byEpisode.count) distinct episodes, \(entries.filter { inWindow($0.watchedAt) }.count) in push windows, "
            + "\(entries.filter(matchesJellyfin).count) at Jellyfin's exact time")
        LogTap.shared.note("[Trakt] DIAG audit R1 (exact duplicates + now-stamped extras): \(r1.count) plays. \(topShows(r1))")
        LogTap.shared.note("[Trakt] DIAG audit R2 (every extra play from the pushes): \(r2.count) plays. \(topShows(r2))")
        let sample = entries.filter { r2.contains($0.id) }.prefix(6).map {
            "\($0.show?.title ?? "?") S\($0.episode?.season ?? -1)E\($0.episode?.number ?? -1) \($0.action) \($0.watchedAt)"
        }
        LogTap.shared.note("[Trakt] DIAG audit sample R2: \(sample)")
    }
}

import Foundation

/// When a start asks the server for pre-rolls (Sodalite#244). Jellyfin-Web asks only for a fresh
/// start; a resume, a channel, a download or anything switched to inside the player never does.
enum PrerollPolicy {
    /// A server that does not answer must not hold the movie back longer than this.
    static let fetchTimeout: Duration = .seconds(3)

    static func shouldFetch(enabled: Bool, itemType: ItemType, isLive: Bool, isLocal: Bool,
                            isMultiviewTile: Bool, isQueuePlayback: Bool, startFromBeginning: Bool,
                            resumeTicks: Int64?, hasResumeOverride: Bool, alreadyConsumed: Bool) -> Bool {
        guard enabled, !alreadyConsumed, itemType == .movie || itemType == .episode else { return false }
        guard !isLive, !isLocal, !isMultiviewTile, !isQueuePlayback, !hasResumeOverride else { return false }
        return startFromBeginning || (resumeTicks ?? 0) <= 0
    }

    /// Server order kept; drops the main item's own id and repeats.
    static func playable(_ intros: [JellyfinItem], mainItemID: String) -> [JellyfinItem] {
        var seen: Set<String> = [mainItemID]
        return intros.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}

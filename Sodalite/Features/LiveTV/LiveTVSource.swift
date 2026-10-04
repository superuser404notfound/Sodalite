import SwiftUI

/// One participant the Live TV tab can run against (Sodalite#85).
struct LiveTVSource {
    let serverID: String
    let serverName: String
    let userID: String
    let liveTvService: JellyfinLiveTvServiceProtocol
    let playbackService: JellyfinPlaybackServiceProtocol
    let itemService: JellyfinItemServiceProtocol
    let isActive: Bool
}

nonisolated enum LiveTVProbe {
    /// Participants exposing at least one channel, in participant order. The active server is asked
    /// without a deadline, as before combining existed. A secondary that fails counts as having none;
    /// one that misses `secondaryDeadline` keeps its last answer from `previouslyCapable`, so one slow
    /// reply does not pull the tab out from under the user.
    static func capableServerIDs(
        _ sources: [LiveTVSource], secondaryDeadline: Duration, previouslyCapable: Set<String> = []
    ) async -> [String] {
        let targets = sources.map { (service: $0.liveTvService, userID: $0.userID, isActive: $0.isActive) }
        let ids = sources.map(\.serverID)
        let keepOnTimeout = ids.map { previouslyCapable.contains($0) }
        // Every child that can hang sits inside Deadline.race, so the group cannot outlive the deadline.
        let capable = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    let probe: @Sendable () async -> Bool = {
                        let response = try? await target.service.getChannels(
                            userID: target.userID, startIndex: 0, limit: 1, filter: .any)
                        return !(response?.items.isEmpty ?? true)
                    }
                    if target.isActive { return (index, await probe()) }
                    return (index, await Deadline.race(secondaryDeadline, probe) ?? keepOnTimeout[index])
                }
            }
            var found: [Int] = []
            for await (index, hasLive) in group where hasLive { found.append(index) }
            return found
        }
        return capable.sorted().map { ids[$0] }
    }
}

nonisolated enum LiveTVServerChoice {
    /// The server under a running player (`pinned`) while it is still a participant, else the
    /// remembered server while it still has Live TV, else the first capable one (active first, then
    /// most recently activated). `available` is the current participants: the capable list lags
    /// behind them until the next probe lands.
    static func resolve(
        capable: [String], available: [String]? = nil, remembered: String?, pinned: String? = nil
    ) -> String? {
        let candidates = available.map { live in capable.filter(live.contains) } ?? capable
        if let pinned, available?.contains(pinned) ?? true { return pinned }
        if let remembered, candidates.contains(remembered) { return remembered }
        return candidates.first
    }
}

enum LiveTVSwitcher {
    static func isVisible(capable: [String]) -> Bool { capable.count > 1 }

    static func options(capable: [String], sources: [LiveTVSource]) -> [CatalogPickerSheet.Option] {
        sources.filter { capable.contains($0.serverID) }.map { .init(id: $0.serverID, label: $0.serverName) }
    }
}

/// What the Live TV tab's user may do on the server it runs against (Sodalite#85). A secondary's
/// rights are its own user's; while that user is unknown the answer is no, which the server would
/// give anyway.
struct LiveTVPolicy {
    let isActiveSource: Bool
    let activeUser: JellyfinUser?
    let sessionUser: JellyfinUser?

    private var user: JellyfinUser? { isActiveSource ? activeUser : sessionUser }
    var canManageLiveTv: Bool { user?.canManageLiveTv == true }
    var canDeleteContent: Bool { user?.canDeleteContent == true }
}

extension EnvironmentValues {
    /// Set by the Live TV tab; nil outside it, where the active user's rights apply.
    @Entry var liveTVPolicy: LiveTVPolicy? = nil
}

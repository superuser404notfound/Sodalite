import Foundation

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
    /// without a deadline, as before combining existed; a secondary that misses `secondaryDeadline`
    /// or fails counts as having none.
    static func capableServerIDs(_ sources: [LiveTVSource], secondaryDeadline: Duration) async -> [String] {
        let targets = sources.map { (service: $0.liveTvService, userID: $0.userID, isActive: $0.isActive) }
        let ids = sources.map(\.serverID)
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
                    return (index, await Deadline.race(secondaryDeadline, probe) ?? false)
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
    /// The remembered server while it still has Live TV, else the first capable one (active first,
    /// then most recently activated).
    static func resolve(capable: [String], remembered: String?) -> String? {
        if let remembered, capable.contains(remembered) { return remembered }
        return capable.first
    }
}

enum LiveTVSwitcher {
    static func isVisible(capable: [String]) -> Bool { capable.count > 1 }

    static func options(capable: [String], sources: [LiveTVSource]) -> [CatalogPickerSheet.Option] {
        sources.filter { capable.contains($0.serverID) }.map { .init(id: $0.serverID, label: $0.serverName) }
    }
}

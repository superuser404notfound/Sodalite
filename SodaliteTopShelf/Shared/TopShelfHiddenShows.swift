import Foundation

/// The shows the active profile hid from Continue Watching and Next Up (`DroppedSeriesStore`),
/// mirrored into the shared container so the shelf leaves them out too. Only series ids of the
/// mirrored session's server cross over, tagged with the user they belong to: the extension
/// applies them only to that same user, so a profile switch that has not reached the shelf yet
/// filters nothing rather than the wrong profile's shows.
///
/// `nonisolated` for the same reason as `TopShelfAccent`: both targets compile this file.
nonisolated struct TopShelfHiddenShows: Codable, Equatable {
    nonisolated static let defaultsKey = "topshelf.hiddenShows"

    let userID: String
    let seriesIDs: [String]
    /// The same profile's hidden shows on its other servers, by server id, for a combined shelf
    /// (Sodalite#218). Optional so a mirror written by an earlier build still decodes.
    var otherServers: [String: [String]]? = nil

    static func read() -> TopShelfHiddenShows? {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let data = defaults.data(forKey: defaultsKey)
        else { return nil }
        return try? JSONDecoder().decode(TopShelfHiddenShows.self, from: data)
    }

    static func write(_ value: TopShelfHiddenShows) {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let data = try? JSONEncoder().encode(value)
        else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The ids to leave out for `userID`, empty when the mirror belongs to someone else.
    func hidden(for userID: String) -> Set<String> {
        userID == self.userID ? Set(seriesIDs) : []
    }

    /// `serverID` nil is the active server. `userID` is always the active profile's: the list
    /// belongs to the profile that hid the shows, whichever server they live on.
    func hidden(for userID: String, serverID: String?) -> Set<String> {
        guard userID == self.userID else { return [] }
        guard let serverID else { return Set(seriesIDs) }
        return Set(otherServers?[serverID] ?? [])
    }
}

nonisolated extension TopShelfItem {
    /// Drops every item whose show is hidden. Movies carry no series id and always stay.
    static func removingHidden(_ items: [TopShelfItem], hidden: Set<String>) -> [TopShelfItem] {
        guard !hidden.isEmpty else { return items }
        return items.filter { item in
            guard let seriesID = item.seriesId else { return true }
            return !hidden.contains(seriesID)
        }
    }
}

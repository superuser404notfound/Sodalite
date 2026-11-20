import Foundation

/// A show taken out of Continue Watching and Next Up from a card's menu. Jellyfin has no "hide from
/// Next Up", so the list lives here, per profile scope like the rows, and travels in the profile's
/// home record. Playing the show again brings it back.
struct DroppedSeries: Codable, Equatable, Identifiable {
    let seriesID: String
    let name: String
    /// The server the show lives on, so two servers' equal ids on a combined Home stay apart.
    let serverID: String

    var id: String { "\(serverID)|\(seriesID)" }
}

enum DroppedSeriesStore {
    private static func key(scope: String) -> String { "homeDroppedSeries.\(scope)" }

    static func load(scope: String) -> [DroppedSeries] {
        guard let data = rawData(scope: scope) else { return [] }
        return (try? JSONDecoder().decode([DroppedSeries].self, from: data)) ?? []
    }

    /// The raw value for cloud sync: nil while the profile never dropped a show.
    static func rawData(scope: String) -> Data? {
        UserDefaults.standard.data(forKey: key(scope: scope))
    }

    static func setRawData(_ data: Data, scope: String) {
        UserDefaults.standard.set(data, forKey: key(scope: scope))
    }

    /// `fallbackServerID` stands in for an item without a `ServerId`, which is the active server's.
    static func drop(_ item: JellyfinItem, fallbackServerID: String, scope: String) {
        guard let entry = entry(for: item, fallbackServerID: fallbackServerID) else { return }
        var list = load(scope: scope)
        guard !list.contains(where: { $0.id == entry.id }) else { return }
        list.append(entry)
        save(list, scope: scope)
    }

    static func restore(_ id: String, scope: String) {
        var list = load(scope: scope)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: index)
        save(list, scope: scope)
    }

    /// Continue Watching and Next Up without the dropped shows. `serverID` is the source the items
    /// came from, for the ones that carry no `ServerId`.
    static func filter(_ items: [JellyfinItem], serverID: String, scope: String) -> [JellyfinItem] {
        let dropped = Set(load(scope: scope).map(\.id))
        guard !dropped.isEmpty else { return items }
        return items.filter { item in
            guard let seriesID = item.seriesId else { return true }
            return !dropped.contains("\(item.serverID ?? serverID)|\(seriesID)")
        }
    }

    /// What the Top Shelf extension gets: the profile's hidden shows on its own server, and on
    /// every other one for a combined shelf (Sodalite#218).
    static func shelfMirror(for profile: ProfileKey) -> TopShelfHiddenShows {
        let list = load(scope: profile.storageScope)
        let others = Dictionary(grouping: list.filter { $0.serverID != profile.serverID }, by: \.serverID)
            .mapValues { $0.map(\.seriesID) }
        return TopShelfHiddenShows(
            userID: profile.userID,
            seriesIDs: list.filter { $0.serverID == profile.serverID }.map(\.seriesID),
            otherServers: others.isEmpty ? nil : others
        )
    }

    static func entry(for item: JellyfinItem, fallbackServerID: String) -> DroppedSeries? {
        guard let seriesID = item.seriesId else { return nil }
        return DroppedSeries(
            seriesID: seriesID,
            name: item.seriesName ?? item.name,
            serverID: item.serverID ?? fallbackServerID
        )
    }

    /// Every write is a home change: the profile record uploads and Home reloads.
    private static func save(_ list: [DroppedSeries], scope: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        setRawData(data, scope: scope)
        NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
    }
}

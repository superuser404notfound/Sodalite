import Foundation

/// One title on the watchlist or a personal list, as much as a card needs.
nonisolated struct TraktListItem: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable { case movie, show }
    let kind: Kind
    let ids: TraktIDs
    let title: String?
    let year: Int?
    let posterURL: URL?

    var id: String { "\(kind.rawValue)-\(TraktKey.keys(ids).first ?? title ?? "?")" }

    init(kind: Kind, ids: TraktIDs, title: String?, year: Int?, posterURL: URL?) {
        self.kind = kind
        self.ids = ids
        self.title = title
        self.year = year
        self.posterURL = posterURL
    }

    init?(_ entry: TraktListEntry) {
        if let movie = entry.movie {
            self.kind = .movie
            self.ids = movie.ids
            self.title = movie.title
            self.year = movie.year
            self.posterURL = movie.images?.posterURL
        } else if let show = entry.show {
            self.kind = .show
            self.ids = show.ids
            self.title = show.title
            self.year = show.year
            self.posterURL = show.images?.posterURL
        } else {
            return nil
        }
    }
}

nonisolated struct TraktListsSnapshot: Codable, Sendable, Equatable {
    struct List: Codable, Sendable, Equatable, Identifiable {
        let id: Int
        let name: String
        let items: [TraktListItem]
    }
    var watchlist: [TraktListItem] = []
    var lists: [List] = []

    func isOnWatchlist(_ ids: TraktIDs) -> Bool {
        let keys = Set(TraktKey.keys(ids))
        return watchlist.contains { !keys.isDisjoint(with: TraktKey.keys($0.ids)) }
    }
}

/// Per-profile files under Caches: the watchlist and lists for the Home rows, and the watched
/// snapshot the sync compares against. Caches, because every byte of it comes back from Trakt.
enum TraktCacheStore {
    private static func directory(_ profile: ProfileKey) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let safe = profile.storageScope.replacingOccurrences(of: ":", with: "_")
        return caches.appendingPathComponent("trakt", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String, profile: ProfileKey) -> T? {
        guard let url = directory(profile)?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String, profile: ProfileKey) {
        guard let dir = directory(profile), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func removeAll(_ profile: ProfileKey) {
        guard let dir = directory(profile) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static let lists = "lists.json"
    static let watched = "watched.json"
}

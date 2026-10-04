import Foundation

/// Sort key for the library grids (Sodalite#78). The raw value is the storage/wire form and must stay
/// stable; `jellyfinValue` is the server's `SortBy`, which is free to differ.
enum LibrarySortKey: String, CaseIterable, Sendable {
    case title
    case releaseDate
    case dateAdded
    case rating
    case runtime

    var jellyfinValue: String {
        switch self {
        case .title: "SortName"
        case .releaseDate: "PremiereDate"
        case .dateAdded: "DateCreated"
        case .rating: "CommunityRating"
        case .runtime: "Runtime"
        }
    }

    /// Direction a freshly picked key starts in: newest, best and longest first everywhere except the alphabet.
    var startsDescending: Bool { self != .title }

    var localizedLabel: String {
        switch self {
        case .title:
            String(localized: "library.sort.key.title", defaultValue: "Title")
        case .releaseDate:
            String(localized: "library.sort.key.releaseDate", defaultValue: "Release date")
        case .dateAdded:
            String(localized: "library.sort.key.dateAdded", defaultValue: "Date added")
        case .rating:
            String(localized: "library.sort.key.rating", defaultValue: "Rating")
        case .runtime:
            String(localized: "library.sort.key.runtime", defaultValue: "Runtime")
        }
    }

    /// Per-key wording, because "descending" reads as Z-A on titles, newest on dates and highest on
    /// ratings; the same two words for all five would leave the user guessing which end they get.
    func localizedDirection(descending: Bool) -> String {
        switch self {
        case .title:
            descending
                ? String(localized: "library.sort.direction.zToA", defaultValue: "Z to A")
                : String(localized: "library.sort.direction.aToZ", defaultValue: "A to Z")
        case .releaseDate, .dateAdded:
            descending
                ? String(localized: "library.sort.direction.newestFirst", defaultValue: "Newest first")
                : String(localized: "library.sort.direction.oldestFirst", defaultValue: "Oldest first")
        case .rating:
            descending
                ? String(localized: "library.sort.direction.highestFirst", defaultValue: "Highest first")
                : String(localized: "library.sort.direction.lowestFirst", defaultValue: "Lowest first")
        case .runtime:
            descending
                ? String(localized: "library.sort.direction.longestFirst", defaultValue: "Longest first")
                : String(localized: "library.sort.direction.shortestFirst", defaultValue: "Shortest first")
        }
    }
}

/// A library grid's sort choice: which key, in which direction.
struct LibrarySort: Equatable, Sendable {
    var key: LibrarySortKey
    var descending: Bool

    /// What every grid shipped with before Sodalite#78, and what an unset or unreadable stored value falls back to.
    static let `default` = LibrarySort(key: .title, descending: false)

    init(key: LibrarySortKey, descending: Bool) {
        self.key = key
        self.descending = descending
    }

    /// Tolerant read for UserDefaults and cloud payloads: a missing value is a fresh install, an
    /// unparsable one a key written by a newer build. Both keep the shipped default rather than
    /// failing the read.
    init(storedValue: String?) {
        guard let storedValue else { self = .default; return }
        let parts = storedValue.split(separator: ":", maxSplits: 1)
        guard let rawKey = parts.first, let key = LibrarySortKey(rawValue: String(rawKey)) else {
            self = .default
            return
        }
        self.key = key
        self.descending = parts.count > 1 ? parts[1] == "desc" : key.startsDescending
    }

    var storageValue: String {
        "\(key.rawValue):\(descending ? "desc" : "asc")"
    }

    /// `SortBy` with SortName appended as the tiebreaker. Half a library carries no premiere date, no
    /// rating or no runtime, and Jellyfin returns those ties in whatever order the query plan hands
    /// over; that order is not stable between requests, so a paginated grid would drop and duplicate
    /// items across page boundaries.
    var jellyfinSortBy: String {
        key == .title ? key.jellyfinValue : "\(key.jellyfinValue),SortName"
    }

    /// One value, not a per-field list: older servers apply a single order to every sort field, so the
    /// SortName tiebreaker runs Z-A under a descending primary. Deterministic either way, which is all
    /// the tiebreaker is there for.
    var jellyfinSortOrder: String {
        descending ? "Descending" : "Ascending"
    }

    /// Applies the choice to a grid query.
    func applied(to query: ItemQuery) -> ItemQuery {
        var copy = query
        copy.sortBy = jellyfinSortBy
        copy.sortOrder = jellyfinSortOrder
        return copy
    }

    /// Tapping the active key flips its direction, tapping another adopts that key's natural one.
    func toggled(to key: LibrarySortKey) -> LibrarySort {
        key == self.key
            ? LibrarySort(key: key, descending: !descending)
            : LibrarySort(key: key, descending: key.startsDescending)
    }

    var localizedSummary: String {
        "\(key.localizedLabel) · \(key.localizedDirection(descending: descending))"
    }
}

/// Identifies which grid a stored sort belongs to: the profile scope it lives in plus a key that is
/// stable across settings the tile's `cacheKey` folds in (the collection-grouping mode changes that one).
struct LibrarySortScope: Hashable, Sendable {
    let scope: String
    let key: String

    static func library(id: String, scope: String) -> LibrarySortScope {
        LibrarySortScope(scope: scope, key: "library-\(id)")
    }

    static func genre(name: String, scope: String) -> LibrarySortScope {
        LibrarySortScope(scope: scope, key: "genre-\(name)")
    }
}

/// Per-profile, per-tile sort choice. Plain `UserDefaults` like `HomeRowConfig`'s other per-server
/// settings; the iCloud mirror rides along in `HomeRowsSyncState` (Sodalite#78).
///
/// The default is written out rather than removed. Collect publishes the whole map and apply is
/// last-writer-wins, so a removed key would read as "this scope was never touched" and let a stale
/// remote entry win a device's deliberate reset back to Title A-Z.
enum LibrarySortStore {
    private static func prefix(scope: String) -> String { "librarySort.\(scope)." }

    static func storageKey(_ scope: LibrarySortScope) -> String {
        prefix(scope: scope.scope) + scope.key
    }

    static func sort(_ scope: LibrarySortScope) -> LibrarySort {
        LibrarySort(storedValue: UserDefaults.standard.string(forKey: storageKey(scope)))
    }

    static func setSort(_ sort: LibrarySort, scope: LibrarySortScope) {
        UserDefaults.standard.set(sort.storageValue, forKey: storageKey(scope))
    }

    /// Every tile this profile scope has a choice for, keyed by scope key. Feeds `collectServerPayload`.
    static func allSorts(scope: String) -> [String: String] {
        let prefix = prefix(scope: scope)
        var result: [String: String] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let stored = value as? String else { continue }
            result[String(key.dropFirst(prefix.count))] = stored
        }
        return result
    }

    /// Writes a cloud payload's map back. Scopes the payload does not mention keep their local value:
    /// the sending device may simply never have opened that tile.
    static func applySorts(_ sorts: [String: String], scope: String) {
        for (scopeKey, stored) in sorts {
            UserDefaults.standard.set(
                stored, forKey: storageKey(LibrarySortScope(scope: scope, key: scopeKey))
            )
        }
    }
}

extension LibrarySort {
    /// The client-side order a merged grid needs, matching what the server returns for this sort:
    /// the key in the chosen direction, items without a value last either way, SortName as the
    /// tiebreaker. nil only for two items the order cannot tell apart.
    func orders(_ lhs: JellyfinItem, before rhs: JellyfinItem) -> Bool? {
        func compare<T: Comparable>(_ l: T?, _ r: T?) -> Bool? {
            switch (l, r) {
            case let (l?, r?): l == r ? nil : (descending ? l > r : l < r)
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): nil
            }
        }
        let primary: Bool?
        switch key {
        case .title: primary = nil
        case .releaseDate: primary = compare(lhs.premiereDate, rhs.premiereDate)
        case .dateAdded: primary = compare(lhs.dateCreated, rhs.dateCreated)
        case .rating: primary = compare(lhs.communityRating, rhs.communityRating)
        case .runtime: primary = compare(lhs.runTimeTicks, rhs.runTimeTicks)
        }
        if let primary { return primary }
        let byName = (lhs.sortName ?? lhs.name).localizedStandardCompare(rhs.sortName ?? rhs.name)
        guard byName != .orderedSame else { return nil }
        // Title sorts honour the direction; for the other keys SortName is a tiebreaker and runs in
        // the same direction, as the server's single SortOrder does.
        return descending ? byName == .orderedDescending : byName == .orderedAscending
    }
}

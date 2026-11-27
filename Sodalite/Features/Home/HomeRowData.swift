import SwiftUI

enum HomeSection: Identifiable {
    case media(HomeRowData)
    case tags(HomeTagRowData)
    case discoverProviders
    case libraries([JellyfinLibrary])
    case trakt(TraktHomeRowData)

    var id: String {
        switch self {
        case .media(let data): data.id
        case .tags(let data): data.id
        case .discoverProviders: "discoverProviders"
        case .libraries: "myMedia"
        case .trakt(let data): "trakt-\(data.id)"
        }
    }
}

struct HomeRowData: Identifiable, Sendable, Codable {
    let type: HomeRowType
    // `var` so HomeViewModel can patch resume progress in place from the playback-stop payload without a full row re-fetch (issue #24). In-place patching keeps the ids, so it cannot break the uniqueness the init establishes.
    var items: [JellyfinItem]
    var libraryID: String? = nil
    var libraryName: String? = nil
    /// The server a per-library row belongs to; nil on a row merged from several (Sodalite#85).
    var serverID: String? = nil
    /// The library's `CollectionType` on a per-library row: "boxsets" makes it a collection shelf
    /// titled with the library's own name rather than "Latest in".
    var collectionType: String? = nil
    /// The server had more than the row shows, so the row ends in a Show All card (Sodalite#258).
    /// Read off the fetch, not off the row's length: a folded Latest row can end short of its cap
    /// with more shows behind it, and a full row can be the whole list.
    var hasMore = false

    /// Ids are unique here (per server, `originKey`), first occurrence wins, because the row renders through `ForEach(items)`
    /// and SwiftUI gives undefined layout when two children claim one identity: the second one
    /// reserves its slot in the LazyHStack and draws nothing (measured on device: two blank cards
    /// mid-row in Latest Series). It is the row builder that can produce a repeat, not the caller's mistake:
    /// Latest Series round-robins one Latest query PER LIBRARY, so a series that lives in two of
    /// them arrives twice by construction. Guaranteed here rather than at that merge, because every
    /// row type reaches the same ForEach and only this type is between all of them and the view.
    init(
        type: HomeRowType,
        items: [JellyfinItem],
        libraryID: String? = nil,
        libraryName: String? = nil,
        serverID: String? = nil,
        collectionType: String? = nil,
        hasMore: Bool = false
    ) {
        self.type = type
        var seen = Set<String>()
        self.items = items.filter { seen.insert($0.originKey).inserted }
        self.libraryID = libraryID
        self.libraryName = libraryName
        self.serverID = serverID
        self.collectionType = collectionType
        self.hasMore = hasMore
    }

    /// Decoding routes through the init above instead of filling the properties directly, so a feed
    /// read back from disk (Sodalite#117) carries the same uniqueness guarantee as one built from a
    /// fetch. A persisted entry was written deduped, which is exactly why the guarantee must not
    /// depend on that having been true.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(HomeRowType.self, forKey: .type)
        let items = try container.decode([JellyfinItem].self, forKey: .items)
        self.init(
            type: type,
            items: items,
            libraryID: try container.decodeIfPresent(String.self, forKey: .libraryID),
            libraryName: try container.decodeIfPresent(String.self, forKey: .libraryName),
            serverID: try container.decodeIfPresent(String.self, forKey: .serverID),
            collectionType: try container.decodeIfPresent(String.self, forKey: .collectionType),
            // A feed written before the flag: a full row is the best guess for its first paint,
            // which is what All Movies and the collection shelves went by until then.
            hasMore: try container.decodeIfPresent(Bool.self, forKey: .hasMore)
                ?? (items.count >= HomeMerger.limit(for: type, mergedContinueWatching: false))
        )
    }

    var isCollectionShelf: Bool { type == .libraryLatest && collectionType == "boxsets" }

    var id: String {
        if type == .libraryLatest, let libraryID {
            return "libraryLatest:\(libraryID)"
        }
        return type.rawValue
    }
}

struct HomeTagRowData: Identifiable, Sendable {
    let type: HomeRowType
    let tags: [TagCardData]

    var id: String { type.rawValue }
}

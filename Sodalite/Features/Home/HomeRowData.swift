import SwiftUI

enum HomeSection: Identifiable {
    case media(HomeRowData)
    case tags(HomeTagRowData)
    case discoverProviders
    case libraries([JellyfinLibrary])

    var id: String {
        switch self {
        case .media(let data): data.id
        case .tags(let data): data.id
        case .discoverProviders: "discoverProviders"
        case .libraries: "myMedia"
        }
    }
}

struct HomeRowData: Identifiable, Sendable {
    let type: HomeRowType
    // `var` so HomeViewModel can patch resume progress in place from the playback-stop payload without a full row re-fetch (issue #24). In-place patching keeps the ids, so it cannot break the uniqueness the init establishes.
    var items: [JellyfinItem]
    var libraryID: String? = nil
    var libraryName: String? = nil

    /// Ids are unique here, first occurrence wins, because the row renders through `ForEach(items)`
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
        libraryName: String? = nil
    ) {
        self.type = type
        var seen = Set<String>()
        self.items = items.filter { seen.insert($0.id).inserted }
        self.libraryID = libraryID
        self.libraryName = libraryName
    }

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

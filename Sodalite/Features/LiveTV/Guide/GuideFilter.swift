import Foundation

/// The guide's channel filters. Only favourites go to the server: Jellyfin drops `Type` on
/// `/LiveTv/Channels` and answers the category flags from channel tags no channel carries (#201),
/// so kind is narrowed on the client and a category through the programs airing now.
struct GuideFilter: Equatable, Sendable {

    /// Category chips: channels whose CURRENT program carries the flag, which is why activating one
    /// snaps the axis back to "now" (see `GuideViewModel`). Resolved by `GuideCategoryController`.
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case sports, kids, news, movies

        var id: String { rawValue }

        /// The program flag. Jellyfin applies these correctly to `/LiveTv/Programs` only.
        var queryName: String {
            switch self {
            case .sports: "IsSports"
            case .kids: "IsKids"
            case .news: "IsNews"
            case .movies: "IsMovie"
            }
        }
    }

    /// Jellyfin's `ChannelType`.
    enum ChannelKind: String, Sendable {
        case tv = "TV"
        case radio = "Radio"
    }

    var favoritesOnly = false
    var category: Category?
    /// nil admits every kind. The guide always narrows to one; the Live TV tab gate does not,
    /// because a radio-only server still has Live TV and must not be gated out of the tab.
    var kind: ChannelKind? = .tv

    static let `default` = GuideFilter()
    /// Every channel the server has, of any kind. Used to answer "does this server do Live TV".
    static let any = GuideFilter(kind: nil)

    var isDefault: Bool { self == .default }

    /// What the server is asked for. Two filters with equal items share one fetched channel list.
    var queryItems: [URLQueryItem] {
        favoritesOnly ? [URLQueryItem(name: "IsFavorite", value: "true")] : []
    }

    func admits(kindOf channel: JellyfinChannel) -> Bool {
        kind.map { channel.kind == $0 } ?? true
    }
}

extension GuideFilter {
    /// Favourites are a lasting choice, a category is a snapshot of what airs now (Sodalite#173).
    var zapLineup: GuideFilter {
        GuideFilter(favoritesOnly: favoritesOnly, category: nil, kind: kind)
    }
}

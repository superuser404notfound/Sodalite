import Foundation

/// Server-side channel filters for the guide. Channel search is deliberately not part of this:
/// Jellyfin cannot filter channels by name, so search stays client-side in `GuideViewModel`.
struct GuideFilter: Equatable, Sendable {

    /// Category chips. Jellyfin applies these to the channel's CURRENT program, not to a channel
    /// genre, which is why activating one snaps the axis back to "now" (see `GuideViewModel`).
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case sports, kids, news, movies

        var id: String { rawValue }

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
    /// nil means no `Type` parameter at all. The guide always sends one; the Live TV tab gate does
    /// not, because a radio-only server still has Live TV and must not be gated out of the tab.
    var kind: ChannelKind? = .tv

    static let `default` = GuideFilter()
    /// Every channel the server has, of any kind. Used to answer "does this server do Live TV".
    static let any = GuideFilter(kind: nil)

    var isDefault: Bool { self == .default }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let kind { items.append(URLQueryItem(name: "Type", value: kind.rawValue)) }
        if favoritesOnly { items.append(URLQueryItem(name: "IsFavorite", value: "true")) }
        if let category { items.append(URLQueryItem(name: category.queryName, value: "true")) }
        return items
    }
}

extension GuideFilter {
    /// Favourites are a lasting choice, a category is a snapshot of what airs now (Sodalite#173).
    var zapLineup: GuideFilter {
        GuideFilter(favoritesOnly: favoritesOnly, category: nil, kind: kind)
    }
}

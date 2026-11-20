import Foundation

/// What the banner at the top of Home pages through, per profile scope like the rows below it.
enum HomeHeroMode: String, CaseIterable {
    case off
    /// The newest titles the viewer has not watched yet (Sodalite#246).
    case recentlyAdded
    /// Unwatched titles from the whole library, shuffled on every load: what the rows below do not show.
    case discover
    case favorites

    static let `default`: HomeHeroMode = .recentlyAdded

    private static func key(scope: String) -> String { "homeHeroMode.\(scope)" }

    static func stored(scope: String) -> HomeHeroMode {
        rawStored(scope: scope).flatMap(HomeHeroMode.init(rawValue:)) ?? .default
    }

    static func setStored(_ mode: HomeHeroMode, scope: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(scope: scope))
    }

    /// The raw value for cloud sync: nil while the profile never chose, so the default stays a default.
    static func rawStored(scope: String) -> String? {
        UserDefaults.standard.string(forKey: key(scope: scope))
    }

    var localizedLabel: String {
        switch self {
        case .off: String(localized: "common.off", defaultValue: "Off")
        case .recentlyAdded: String(localized: "home.recentlyAdded", defaultValue: "Recently Added")
        case .discover: String(localized: "catalog.tab.discover", defaultValue: "Discover")
        case .favorites: String(localized: "home.favorites", defaultValue: "Favorites")
        }
    }
}

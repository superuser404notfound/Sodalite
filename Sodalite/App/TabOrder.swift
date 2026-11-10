import Foundation

/// Sodalite#235: the viewer's own order of the navigation tabs, app tabs and pinned libraries mixed.
///
/// Stored as a list of keys rather than of tabs, so a tab only a newer build knows, or a library pin
/// this device has not seen yet, survives the trip through the profile's sync record. Home, Settings
/// and the profile switcher have no key: Home is the landing tab and the other two are the bar's tail
/// (the sidebar even draws them apart), so they never move.
enum TabOrder {

    static func key(for tab: ShellTab) -> String? {
        switch tab {
        case .app(let app): key(for: app)
        case .library(let pin): "library:\(pin.originKey)"
        }
    }

    static func key(for tab: AppTab) -> String? {
        switch tab {
        case .home, .settings, .profiles: nil
        case .liveTV, .music, .catalog, .search, .downloads: tab.rawValue
        }
    }

    /// `tabs` in the stored order. The slots the ordered tabs hold in the default arrangement are
    /// refilled with them in stored order; everything else keeps its slot. So the fixed tabs stay
    /// where they are, and a tab the order does not name yet (a pin from another device, Live TV on
    /// a server that just gained it) appears where it would without a custom order.
    static func arrange<T>(_ tabs: [T], by order: [String], key: (T) -> String?) -> [T] {
        guard !order.isEmpty else { return tabs }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = tabs.indices.filter { key(tabs[$0]).flatMap { rank[$0] } != nil }
        let sorted = ranked.map { tabs[$0] }.sorted { rank[key($0)!]! < rank[key($1)!]! }
        var result = tabs
        for (slot, tab) in zip(ranked, sorted) {
            result[slot] = tab
        }
        return result
    }

    static func arrange(_ tabs: [ShellTab], by order: [String]) -> [ShellTab] {
        arrange(tabs, by: order, key: key(for:))
    }
}

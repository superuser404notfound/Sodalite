import SwiftUI

enum AppTab: String, CaseIterable, Sendable {
    case home
    case liveTV
    case catalog
    case search
    case music
    /// Sodalite#81, iOS only, and only while the profile has downloads.
    case downloads
    case settings

    /// Home is the landing tab and Settings the only route back to the settings screen on tvOS,
    /// so hiding either would strand the user. Everything else is the user's choice (Sodalite#62).
    var isHideable: Bool {
        switch self {
        case .home, .settings: false
        case .liveTV, .catalog, .search, .music, .downloads: true
        }
    }

    /// The switchable tabs, in the order the settings screen lists them.
    static var hideableCases: [AppTab] {
        #if os(iOS)
        allCases.filter(\.isHideable)
        #else
        allCases.filter { $0.isHideable && $0 != .downloads }
        #endif
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .home: "tab.home"
        case .liveTV: "tab.liveTV"
        case .catalog: "tab.catalog"
        case .search: "tab.search"
        case .music: "tab.music"
        case .downloads: "tab.downloads"
        case .settings: "tab.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .liveTV: "tv"
        case .catalog: "film.stack"
        case .search: "magnifyingglass"
        case .music: "music.note"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

// MARK: - Optional tabs

/// Live TV and Music exist only on servers that offer them, so the tab set is probed per server
/// and assembled here. One function, because the three probe sites (server switch, login
/// completion, outage recovery) each carried their own copy of the same assembly and drifted
/// apart (Sodalite#141).
extension AppTab {
    /// The tabs every server has. The probed set is built by inserting into this.
    static var baseTabs: [AppTab] {
        allCases.filter { $0 != .music && $0 != .liveTV && $0 != .downloads }
    }

    /// Order: Home, [Live TV,] Catalog, Search, [Music,] [Downloads,] Settings.
    static func probedTabs(hasLiveTV: Bool, hasMusic: Bool, hasDownloads: Bool = false) -> [AppTab] {
        var tabs = baseTabs
        if hasLiveTV, let homeIndex = tabs.firstIndex(of: .home) {
            tabs.insert(.liveTV, at: homeIndex + 1)
        }
        if hasMusic, let settingsIndex = tabs.firstIndex(of: .settings) {
            tabs.insert(.music, at: settingsIndex)
        }
        return withDownloads(tabs, hasDownloads: hasDownloads)
    }

    /// Sodalite#81. Inserted at display time rather than by the probe sites: a download finishing
    /// must not re-run a server probe, and on tvOS nothing downloads, so this never touches its bar.
    static func withDownloads(_ tabs: [AppTab], hasDownloads: Bool) -> [AppTab] {
        #if os(iOS)
        guard hasDownloads, !tabs.contains(.downloads) else { return tabs }
        var tabs = tabs
        tabs.insert(.downloads, at: tabs.firstIndex(of: .settings) ?? tabs.endIndex)
        return tabs
        #else
        return tabs
        #endif
    }
}

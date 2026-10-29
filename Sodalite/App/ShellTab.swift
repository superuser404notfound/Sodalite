import SwiftUI

/// A place in the navigation shell: one of the app's own tabs, or a library the viewer pinned as a
/// tab of its own (tvOS and iPad). `AppTab` stays the closed set the settings, the sync payloads and the
/// optional-tab probes reason about; only the shell and its selection know about libraries.
enum ShellTab: Hashable, Sendable {
    case app(AppTab)
    case library(PinnedLibraryTab)

    // So the shells and their policies keep writing `.home` and `.settings`.
    static let home = ShellTab.app(.home)
    static let liveTV = ShellTab.app(.liveTV)
    static let music = ShellTab.app(.music)
    static let catalog = ShellTab.app(.catalog)
    static let search = ShellTab.app(.search)
    static let downloads = ShellTab.app(.downloads)
    static let settings = ShellTab.app(.settings)
    static let profiles = ShellTab.app(.profiles)

    /// The iPhone bar has no room for pins, and the Mac's sidebar is not the bar they were asked for.
    @MainActor
    static var supportsLibraryTabs: Bool {
        #if os(tvOS)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    var appTab: AppTab? {
        if case .app(let tab) = self { tab } else { nil }
    }

    var systemImage: String {
        switch self {
        case .app(let tab): tab.systemImage
        case .library(let library): library.systemImage
        }
    }

    var title: Text {
        switch self {
        case .app(let tab): Text(tab.labelKey)
        case .library(let library): Text(verbatim: library.name)
        }
    }
}

/// A library pinned as a tab. Name and type are kept with the pin, so the bar is complete on the
/// first frame instead of waiting for the library list; the settings screen refreshes them.
struct PinnedLibraryTab: Codable, Hashable, Sendable {
    let serverID: String?
    let libraryID: String
    var name: String
    var collectionType: String?

    init(library: JellyfinLibrary) {
        serverID = library.serverID
        libraryID = library.id
        name = library.name
        collectionType = library.collectionType
    }

    /// The same identity `JellyfinLibrary.originKey` gives the library.
    var originKey: String { "\(serverID ?? "")|\(libraryID)" }

    var library: JellyfinLibrary {
        JellyfinLibrary(id: libraryID, name: name, collectionType: collectionType, imageTags: nil, serverID: serverID)
    }

    var systemImage: String {
        switch library.libraryType {
        case .movies: "film"
        case .tvshows: "play.tv"
        case .homevideos: "video"
        case .boxsets: "square.stack"
        case .playlists: "list.bullet"
        default: "square.grid.2x2"
        }
    }
}

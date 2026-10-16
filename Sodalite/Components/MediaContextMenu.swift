import SwiftUI

extension EnvironmentValues {
    /// Starts playback of an item from a card's context menu, where the screen can (Home opens the
    /// detail page with autoplay). Nil leaves Play out of the menu.
    @Entry var playMediaItem: PlayMediaItemAction?
}

/// Always equal: its one publisher (Home) routes into state storage that outlives every render, so
/// a fresh closure per render changes nothing a reader needs to see.
struct PlayMediaItemAction: Equatable {
    let perform: (JellyfinItem) -> Void

    func callAsFunction(_ item: JellyfinItem) { perform(item) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension View {
    /// The Mac's right-click menu on a media card: open it, play it, and the two per-user marks
    /// the detail page offers. A Mac-only addition; elsewhere this returns the card unchanged.
    @ViewBuilder
    func mediaContextMenu(for item: JellyfinItem, onOpen: @escaping () -> Void) -> some View {
        #if os(macOS)
        contextMenu { MediaContextMenu(item: item, onOpen: onOpen) }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MediaContextMenu: View {
    let item: JellyfinItem
    let onOpen: () -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.playMediaItem) private var playMediaItem

    private var isPlayed: Bool { item.userData?.played ?? false }
    private var isFavorite: Bool { item.userData?.isFavorite ?? false }
    private var hasPosition: Bool { (item.userData?.playbackPositionTicks ?? 0) > 0 }

    /// Watched on a series cascades to every episode, which the detail page asks before doing; a
    /// menu item has nowhere to ask, so it is offered only where one click means one title.
    private var offersWatched: Bool { item.type == .movie || item.type == .episode }

    var body: some View {
        Button("detail.episode.showDetails", systemImage: "info.circle", action: onOpen)

        if let playMediaItem, item.type == .movie || item.type == .episode || item.type == .series {
            Button(hasPosition ? "detail.resume" : "detail.play", systemImage: "play.fill") {
                playMediaItem(item)
            }
        }

        Divider()

        if offersWatched {
            Button(
                isPlayed ? "contextMenu.markUnwatched" : "contextMenu.markWatched",
                systemImage: isPlayed ? "eye.slash" : "checkmark.circle"
            ) {
                setPlayed(!isPlayed)
            }
        }

        Button(
            isFavorite ? "contextMenu.unfavorite" : "contextMenu.favorite",
            systemImage: isFavorite ? "heart.slash" : "heart"
        ) {
            setFavorite(!isFavorite)
        }
    }

    /// Same calls and the same refresh signals as the detail page's buttons, against the server
    /// the card came from, so a combined Home's secondary title is marked where it lives.
    private func setPlayed(_ played: Bool) {
        let session = dependencies.sessionRegistry.session(for: item)
        let itemID = item.id
        Task {
            try? await session.itemService.setPlayed(userID: session.userID, itemID: itemID, isPlayed: played)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
        }
    }

    private func setFavorite(_ favorite: Bool) {
        let session = dependencies.sessionRegistry.session(for: item)
        let itemID = item.id
        Task {
            try? await session.itemService.setFavorite(userID: session.userID, itemID: itemID, isFavorite: favorite)
            NotificationCenter.default.post(name: .homeFavoritesDidChange, object: nil)
        }
    }
}
#endif

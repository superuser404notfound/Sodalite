import SwiftUI

extension EnvironmentValues {
    /// Starts playback of an item from a card's context menu, where the screen can (Home opens the
    /// detail page with autoplay). Nil leaves Play out of the menu.
    @Entry var playMediaItem: PlayMediaItemAction?
    /// Takes a card's show out of Continue Watching and Next Up. Set only on those rows, where the
    /// entry means something.
    @Entry var dropSeries: DropSeriesAction?
}

/// Always equal: its one publisher (Home) routes into state storage that outlives every render, so
/// a fresh closure per render changes nothing a reader needs to see.
struct PlayMediaItemAction: Equatable {
    let perform: (JellyfinItem, _ fromBeginning: Bool) -> Void

    func callAsFunction(_ item: JellyfinItem, fromBeginning: Bool = false) { perform(item, fromBeginning) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// Always equal, for the same reason as `PlayMediaItemAction`.
struct DropSeriesAction: Equatable {
    let perform: (JellyfinItem) -> Void

    func callAsFunction(_ item: JellyfinItem) { perform(item) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension View {
    /// A media card's hold (tvOS, iOS) or right-click (Mac) menu: open it, its show, play it, and the
    /// per-user marks the detail page offers. `open` takes the item to show, which for Go to Show is
    /// the card's series rather than the card. A card whose tap goes through `stableTap` must set
    /// `longPressOpensMenu`, or the press opens the card on its way into the menu (Sodalite#75).
    func mediaContextMenu(for item: JellyfinItem, open: @escaping (JellyfinItem) -> Void) -> some View {
        contextMenu { MediaContextMenu(item: item, open: open) }
    }
}

private struct MediaContextMenu: View {
    let item: JellyfinItem
    let open: (JellyfinItem) -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.playMediaItem) private var playMediaItem
    @Environment(\.dropSeries) private var dropSeries

    private var isPlayed: Bool { item.userData?.played ?? false }
    private var isFavorite: Bool { item.userData?.isFavorite ?? false }
    private var hasPosition: Bool { (item.userData?.playbackPositionTicks ?? 0) > 0 }

    /// Watched on a series cascades to every episode, which the detail page asks before doing; a
    /// menu item has nowhere to ask, so it is offered only where one click means one title.
    private var offersWatched: Bool { item.type == .movie || item.type == .episode }

    var body: some View {
        Button("detail.episode.showDetails", systemImage: "info.circle") { open(item) }

        if item.type == .episode, let seriesID = item.seriesId {
            Button("contextMenu.goToShow", systemImage: "tv") {
                var series = JellyfinItem(seriesStub: seriesID, name: item.seriesName ?? "")
                series.serverID = item.serverID
                open(series)
            }
        }

        if let playMediaItem, item.type == .movie || item.type == .episode || item.type == .series {
            Button(hasPosition ? "detail.resume" : "detail.play", systemImage: "play.fill") {
                playMediaItem(item)
            }
            if hasPosition, offersWatched {
                Button("contextMenu.playFromBeginning", systemImage: "arrow.counterclockwise") {
                    playMediaItem(item, fromBeginning: true)
                }
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

        if hasPosition, offersWatched {
            Button("contextMenu.removeFromContinueWatching", systemImage: "xmark.circle") {
                clearPosition()
            }
        }

        if let dropSeries, item.seriesId != nil {
            Button("contextMenu.hideShow", systemImage: "minus.circle") { dropSeries(item) }
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

    private func clearPosition() {
        let session = dependencies.sessionRegistry.session(for: item)
        let itemID = item.id
        Task {
            try? await session.itemService.clearPlaybackPosition(userID: session.userID, itemID: itemID)
            NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
        }
    }
}

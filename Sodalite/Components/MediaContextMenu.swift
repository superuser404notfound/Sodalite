import SwiftUI

extension EnvironmentValues {
    /// Starts playback of an item from a card's context menu, where the screen can (Home opens the
    /// detail page with autoplay). Nil leaves Play out of the menu.
    @Entry var playMediaItem: PlayMediaItemAction?
    /// Takes a card's show out of Continue Watching and Next Up. Set only on those rows, where the
    /// entry means something.
    @Entry var dropSeries: DropSeriesAction?
    /// Asks to mark every episode of a card's show unwatched. The screen confirms first, a menu has
    /// nowhere to ask. Set on the same rows as `dropSeries`.
    @Entry var removeSeriesHistory: DropSeriesAction?
    /// Told when a card's hold is about to open its menu, which takes focus off the row. Home needs
    /// to tell that apart from the move to the tab bar, which looks the same to its focus state.
    @Entry var cardMenuWillOpen: (() -> Void)?
}

/// Always equal: its one publisher (Home) routes into state storage that outlives every render, so
/// a fresh closure per render changes nothing a reader needs to see.
struct PlayMediaItemAction: Equatable {
    let perform: (JellyfinItem, _ fromBeginning: Bool) -> Void

    func callAsFunction(_ item: JellyfinItem, fromBeginning: Bool = false) { perform(item, fromBeginning) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// Always equal, for the same reason as `PlayMediaItemAction`. Also carries Remove All History,
/// which takes the same card and is published by the same rows.
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
    ///
    /// On tvOS the remote's Play button on the focused card starts the same playback as the menu's
    /// Play (Sodalite#196), the way the TV app, Netflix and Hulu answer it.
    func mediaContextMenu(for item: JellyfinItem, open: @escaping (JellyfinItem) -> Void) -> some View {
        modifier(MediaContextMenuHost(item: item, open: open))
            .modifier(PlayButtonStartsPlayback(item: item))
    }
}

/// Holds the card's download request, because a context menu closes before anything it starts could
/// ask a question. The quality dialog hangs off the card itself (on iPad, a popover at the card) and
/// not off a shell-level host, because cards also live inside detail covers, where a dialog from the
/// shell under the cover would never show.
private struct MediaContextMenuHost: ViewModifier {
    let item: JellyfinItem
    let open: (JellyfinItem) -> Void

    #if os(tvOS)
    func body(content: Content) -> some View {
        content.contextMenu { MediaContextMenu(item: item, open: open, requestDownload: nil) }
    }
    #else
    @State private var downloadTarget: DownloadTarget?
    @Environment(\.dependencies) private var dependencies

    func body(content: Content) -> some View {
        content
            .contextMenu {
                MediaContextMenu(item: item, open: open) { requestDownload() }
            }
            .downloadRungDialog(target: $downloadTarget)
    }

    /// A list card carries no MediaSources, so the dialog would have no sizes and the download would
    /// take the server's first version instead of the one Play starts. The fetch also puts the
    /// dialog after the menu's dismissal, which a presentation during it can collide with.
    private func requestDownload() {
        downloadTarget = nil
        let card = item
        let session = dependencies.sessionRegistry.session(for: card)
        Task {
            var detail = (try? await session.itemService.getItemDetail(userID: session.userID, itemID: card.id)) ?? card
            detail.serverID = card.serverID
            downloadTarget = .item(detail, sourceID: nil)
        }
    }
    #endif
}

extension PlayMediaItemAction {
    /// The card types whose Play goes straight to the player: a series plays its next episode.
    static func plays(_ item: JellyfinItem) -> Bool {
        item.type == .movie || item.type == .episode || item.type == .series
    }
}

/// Attached only where the screen publishes `playMediaItem` and the card can play, because a
/// handler here takes the press from the tab root's music toggle above it.
private struct PlayButtonStartsPlayback: ViewModifier {
    let item: JellyfinItem

    @Environment(\.dependencies) private var dependencies
    @Environment(\.playMediaItem) private var playMediaItem

    func body(content: Content) -> some View {
        if let playMediaItem, PlayMediaItemAction.plays(item) {
            content.onPlayPauseCommandCompat {
                // Background music keeps the button it already had.
                let music = dependencies.musicPlaybackCoordinator
                if music.currentItem != nil {
                    music.togglePlayPause()
                } else {
                    playMediaItem(item)
                }
            }
        } else {
            content
        }
    }
}

private struct MediaContextMenu: View {
    let item: JellyfinItem
    let open: (JellyfinItem) -> Void
    /// Nil on tvOS, where nothing downloads.
    let requestDownload: (() -> Void)?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.playMediaItem) private var playMediaItem
    @Environment(\.dropSeries) private var dropSeries
    @Environment(\.removeSeriesHistory) private var removeSeriesHistory

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

        if let playMediaItem, PlayMediaItemAction.plays(item) {
            Button(hasPosition ? "detail.resume" : "detail.play", systemImage: "play.fill") {
                playMediaItem(item)
            }
            if hasPosition, offersWatched {
                Button("contextMenu.playFromBeginning", systemImage: "arrow.counterclockwise") {
                    playMediaItem(item, fromBeginning: true)
                }
            }
        }

        // Movies and episodes only: a series has no single file, and its seasons download from the
        // show page. Hidden once the title is queued or on the device; the detail page manages those.
        if let requestDownload, offersWatched, dependencies.downloadManager != nil,
           dependencies.downloadStore.item(item.id) == nil {
            Button("downloads.action.download", systemImage: "arrow.down.circle") { requestDownload() }
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

        if let removeSeriesHistory, item.seriesId != nil {
            Button("contextMenu.removeShowHistory", systemImage: "trash", role: .destructive) {
                removeSeriesHistory(item)
            }
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

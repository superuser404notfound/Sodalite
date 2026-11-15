import SwiftUI

struct DetailRouterView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.serverSession) private var inheritedSession
    let item: JellyfinItem
    /// TopShelf playAction: start playback as soon as the detail view model is ready. Collections and playlists ignore it; the shelf never emits them and "play a collection" is not a defined action.
    var autoPlay: Bool = false
    /// With `autoPlay`: start at zero instead of the resume position (a card menu's "Play from Beginning").
    var autoPlayFromBeginning: Bool = false

    /// The copy of the film on another combined server the viewer picked a version of (Sodalite#240).
    /// The page moves over to it whole, so progress, favourite and playback all answer to that
    /// server and never mix two servers' state on one screen.
    @State private var twinRoute: TwinRoute?

    private struct TwinRoute {
        let item: JellyfinItem
        let sourceID: String
    }

    private var shown: JellyfinItem { twinRoute?.item ?? item }

    var body: some View {
        Group {
            switch item.type {
            case .movie:
                MovieDetailView(
                    item: shown,
                    autoPlay: autoPlay && twinRoute == nil,
                    autoPlayFromBeginning: autoPlayFromBeginning,
                    initialSourceID: twinRoute?.sourceID
                )
                // A fresh page, not an updated one: its view model, version pick and twin lookup
                // all belong to the item they were built for.
                .id(shown.originKey)
            case .series:
                SeriesDetailView(item: item, autoPlay: autoPlay, autoPlayFromBeginning: autoPlayFromBeginning)
            case .episode:
                if let seriesId = item.seriesId {
                    SeriesDetailView(
                        item: JellyfinItem(seriesStub: seriesId, name: item.seriesName ?? ""),
                        initialEpisode: item,
                        autoPlay: autoPlay,
                        autoPlayFromBeginning: autoPlayFromBeginning
                    )
                } else {
                    // No parent series to show: fall back to the
                    // standalone episode page.
                    MovieDetailView(item: item, autoPlay: autoPlay, autoPlayFromBeginning: autoPlayFromBeginning)
                }
            case .boxSet:
                CollectionDetailView(item: item)
            case .playlist:
                PlaylistDetailView(item: item)
            default:
                MovieDetailView(item: item, autoPlay: autoPlay, autoPlayFromBeginning: autoPlayFromBeginning)
            }
        }
        .hidesShellTabBar()
        .environment(\.serverSession, session)
        .environment(\.switchToServerTwin) { twin, source in
            // Back on the page's own copy: the route goes, so the page is the one it opened as.
            twinRoute = twin.item.originKey == item.originKey ? nil : TwinRoute(item: twin.item, sourceID: source.id)
        }
        .modifier(ThemeSongClaim(itemID: themeSongItemID, session: session))
    }

    /// Sodalite#219. An episode plays its series' song (the server inherits it); a playlist has none.
    private var themeSongItemID: String? {
        switch item.type {
        case .movie, .series, .season, .boxSet: shown.id
        case .episode: item.seriesId
        default: nil
        }
    }

    /// An item without a `ServerId` (the series stub built for an episode) stays on the session it
    /// was opened from.
    private var session: ServerSession {
        guard shown.serverID != nil else { return inheritedSession ?? dependencies.sessionRegistry.active }
        return dependencies.sessionRegistry.session(for: shown)
    }
}

extension EnvironmentValues {
    /// Moves the detail page onto another server's copy of its film, standing on `source`
    /// (Sodalite#240). nil outside a `DetailRouterView`.
    @Entry var switchToServerTwin: ((ServerTwin, MediaSource) -> Void)? = nil
}

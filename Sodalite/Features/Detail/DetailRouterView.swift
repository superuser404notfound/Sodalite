import SwiftUI

struct DetailRouterView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.serverSession) private var inheritedSession
    let item: JellyfinItem
    /// TopShelf playAction: start playback as soon as the detail view model is ready. Collections and playlists ignore it; the shelf never emits them and "play a collection" is not a defined action.
    var autoPlay: Bool = false

    var body: some View {
        Group {
            switch item.type {
            case .movie:
                MovieDetailView(item: item, autoPlay: autoPlay)
            case .series:
                SeriesDetailView(item: item, autoPlay: autoPlay)
            case .episode:
                if let seriesId = item.seriesId {
                    SeriesDetailView(
                        item: JellyfinItem(seriesStub: seriesId, name: item.seriesName ?? ""),
                        initialEpisode: item,
                        autoPlay: autoPlay
                    )
                } else {
                    // No parent series to show: fall back to the
                    // standalone episode page.
                    MovieDetailView(item: item, autoPlay: autoPlay)
                }
            case .boxSet:
                CollectionDetailView(item: item)
            case .playlist:
                PlaylistDetailView(item: item)
            default:
                MovieDetailView(item: item, autoPlay: autoPlay)
            }
        }
        .hidesShellTabBar()
        .environment(\.serverSession, session)
    }

    /// An item without a `ServerId` (the series stub built for an episode) stays on the session it
    /// was opened from.
    private var session: ServerSession {
        guard item.serverID != nil else { return inheritedSession ?? dependencies.sessionRegistry.active }
        return dependencies.sessionRegistry.session(for: item)
    }
}

import SwiftUI

/// Adds the title to the Trakt watchlist or takes it off. Only shown while Trakt is connected.
struct TraktWatchlistButton: View {
    let item: JellyfinItem

    @Environment(\.dependencies) private var dependencies
    @State private var errorText: String?

    var body: some View {
        let trakt = dependencies.trakt
        let onList = trakt.isOnWatchlist(item)
        GlassActionButton(
            title: onList ? "trakt.watchlist.remove" : "trakt.watchlist.add",
            systemImage: onList ? "bookmark.fill" : "bookmark",
            action: {
                Task {
                    do {
                        try await trakt.setOnWatchlist(item, !onList)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        )
        .alert("settings.trakt.title", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(verbatim: errorText ?? "")
        }
    }
}

import SwiftUI

extension View {
    /// Fills in the badge pills for a row or grid of items once it is on screen (Sodalite#79).
    /// Attach it to the container, never to a card: the point is that one request covers the whole
    /// row rather than one per card.
    func enrichesPosterBadges(_ items: [JellyfinItem]) -> some View {
        modifier(PosterBadgeEnrichment(key: items.map(\.id), items: { items }))
    }

    /// For a grid that would have to copy every loaded item on each body just to build the task id:
    /// `key` stands for the content and the items are only read when the task runs (BRW-209).
    func enrichesPosterBadges(revision: Int, items: @escaping () -> [JellyfinItem]) -> some View {
        modifier(PosterBadgeEnrichment(key: revision, items: items))
    }
}

private struct PosterBadgeEnrichment: ViewModifier {
    let key: AnyHashable
    let items: () -> [JellyfinItem]

    init(key: some Hashable, items: @escaping () -> [JellyfinItem]) {
        self.key = AnyHashable(key)
        self.items = items
    }

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appState) private var appState

    func body(content: Content) -> some View {
        content
            // The setting is part of the id so switching it on fills the corners in without a
            // reload; the ids so a row that swapped its content enriches the new one.
            .task(id: EnrichmentKey(key: key,
                                    enabled: dependencies.appearancePreferences.showPosterBadges)) {
                guard let userID = appState.activeUser?.id else { return }
                await dependencies.posterBadgeStore.enrich(userID: userID, items())
            }
    }

    private struct EnrichmentKey: Equatable {
        let key: AnyHashable
        let enabled: Bool
    }
}

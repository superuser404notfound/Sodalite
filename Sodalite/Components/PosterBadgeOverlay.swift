import SwiftUI

/// The pills in a card's top-left corner (Sodalite#79).
///
/// A leaf on purpose: it, not `MediaCard`, reads the badge store, so a batch of enrichment landing
/// invalidates the overlays and not the two hundred cards around them. The top right belongs to the
/// watched checkmark and the bottom edge to the resume bar, so the corner is free.
struct PosterBadgeOverlay: View {
    let item: JellyfinItem
    let fontSize: CGFloat

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        if dependencies.appearancePreferences.showPosterBadges {
            let pills = dependencies.posterBadgeStore.badges(for: item).pills
            if !pills.isEmpty {
                PosterBadgePills(pills: pills, fontSize: fontSize)
            }
        }
    }
}

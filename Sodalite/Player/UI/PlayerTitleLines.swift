import Foundation

/// The two lines every player title surface draws: the header, and the identity line under it.
///
/// Three surfaces derived this separately (the tvOS title overlay, the iOS touch controls' top bar
/// and the AirPlay backdrop), and two of them took `item.name` raw as the second line while only
/// the tvOS one ran it through `EpisodeMetadataFormatter`. A header and a subtitle carrying the
/// same string were therefore drawn twice on iOS, which Sodalite#159 makes reachable on every live
/// programme that has no episode of its own: a live item's header falls back to the programme name,
/// and `name` holds that same name.
nonisolated struct PlayerTitleLines: Equatable, Sendable {
    let header: String
    let subtitle: String?

    init(item: JellyfinItem) {
        header = item.seriesName ?? item.name
        guard item.seriesName != nil else {
            // A movie, stored or live (Sodalite#159): its name over its year.
            subtitle = item.productionYear.map { String($0) }
            return
        }
        let line = EpisodeMetadataFormatter.episodeLine(under: item.seriesName,
                                                        season: item.parentIndexNumber,
                                                        episode: item.indexNumber,
                                                        title: item.name)
        subtitle = line.isEmpty ? nil : line
    }
}

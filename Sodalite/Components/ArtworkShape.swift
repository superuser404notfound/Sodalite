import Foundation

/// The card shape a server asks for through `PrimaryImageAspectRatio`. Jellyfin reports the real
/// ratio of each primary image, and a server that curates its own folders (landscape covers for a
/// "Streaming Services" shelf, square ones for genres) says so through the same field, so a poster
/// row honours it instead of cropping a 16:9 cover into a 2:3 slot.
enum ArtworkShape {
    /// The card one primary image is drawn as. nil when the server gave no ratio.
    static func style(forAspectRatio ratio: Double?) -> MediaCardStyle? {
        guard let ratio, ratio > 0 else { return nil }
        if ratio >= 1.3 { return .landscape }
        if ratio >= 0.85 { return .square }
        return .poster
    }

    /// A poster row or grid takes the shape most of its own images have. Only items with a primary
    /// image of their own vote: an episode drawn with its series poster says nothing about the row.
    /// A row that is landscape or square by design keeps its style.
    static func style(for items: [JellyfinItem], default fallback: MediaCardStyle) -> MediaCardStyle {
        guard fallback == .poster else { return fallback }
        let votes = items.lazy
            .filter { $0.imageTags?.primary != nil }
            .compactMap { style(forAspectRatio: $0.primaryImageAspectRatio) }
        let counts = Dictionary(votes.map { ($0, 1) }, uniquingKeysWith: +)
        let total = counts.values.reduce(0, +)
        for candidate in [MediaCardStyle.landscape, .square] where (counts[candidate] ?? 0) * 2 > total {
            return candidate
        }
        return fallback
    }

    /// Width to ask the server for, so a landscape cover is not upscaled from a poster-sized fetch.
    static func imageWidth(for style: MediaCardStyle) -> Int {
        style == .landscape ? ImageWidth.wideCard : ImageWidth.card
    }
}

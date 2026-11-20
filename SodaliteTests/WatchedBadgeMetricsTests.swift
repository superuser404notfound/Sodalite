import Testing
import Foundation
@testable import Sodalite

/// The watched check used to be a fixed `.title3`, which measured near 17 percent of the poster on
/// both tiers, grew with Dynamic Type on iOS, and stayed put while the card-scale setting shrank the
/// card under it (Sodalite#89). What is pinned here is the intent, not the constant: the band every
/// comparable client sits in, and the two things the old fixed size could not do.
struct WatchedBadgeMetricsTests {

    private let tiers: [(name: String, metrics: LayoutMetrics)] = [
        ("tvOS", .tv), ("iPad", .regular), ("iPhone", .compact),
    ]

    @Test func theDiscStaysInsideTheTwelveToSixteenPercentBandOnEveryTier() {
        for tier in tiers {
            let width = tier.metrics.posterSize.width
            let ratio = PosterBadgeMetrics.checkDiameter(posterWidth: width, scale: 1) / width
            #expect(ratio >= 0.12 && ratio <= 0.16, "\(tier.name) badge is \(ratio * 100)% of the poster")
        }
    }

    /// Every card scale the Appearance setting offers, so the badge cannot drift out of the band at
    /// either end of the slider.
    @Test func theBandHoldsAtEveryCardScale() {
        for scale in [0.8, 0.9, 1.0, 1.1, 1.25, 1.4] as [CGFloat] {
            for tier in tiers {
                let cardWidth = tier.metrics.posterSize.width * scale
                let diameter = PosterBadgeMetrics.checkDiameter(posterWidth: tier.metrics.posterSize.width, scale: scale)
                let ratio = diameter / cardWidth
                #expect(ratio >= 0.12 && ratio <= 0.16, "\(tier.name) at \(scale) is \(ratio * 100)%")
            }
        }
    }

    /// The old fixed size did not move with the setting at all; a shrunk card wore a full-size badge.
    @Test func theBadgeTracksTheCardScale() {
        let width = LayoutMetrics.tv.posterSize.width
        let small = PosterBadgeMetrics.checkDiameter(posterWidth: width, scale: 0.8)
        let large = PosterBadgeMetrics.checkDiameter(posterWidth: width, scale: 1.25)

        #expect(small < large)
        // Ratio, not equality: the two sides are the same product in a different order and land a
        // float ULP apart.
        #expect(abs(large / small - 1.25 / 0.8) < 0.0001)
    }

    /// Both surfaces read the tier's POSTER width, never the card's own. A landscape still is 360pt
    /// wide against a 220pt poster on tvOS, so sizing off the card would put a 47pt badge next to a
    /// 29pt one in the same row.
    @Test func bothSurfacesSizeTheBadgeOffThePosterWidth() throws {
        #expect(LayoutMetrics.tv.landscapeSize.width > LayoutMetrics.tv.posterSize.width)

        let card = try source("Sodalite/Components/MediaCard.swift")
        #expect(card.contains("posterWidth: tierPosterWidth"))
        #expect(card.contains("private var tierPosterWidth: CGFloat { LayoutMetrics.current(hSizeClass).posterSize.width }"))

        let episode = try source("Sodalite/Features/Detail/EpisodeRowComponents.swift")
        #expect(episode.contains("posterWidth: LayoutMetrics.current(hSizeClass).posterSize.width"))
        #expect(!episode.contains("Image(systemName: \"checkmark.circle.fill\")"))
    }

    /// The glyph is drawn, not knocked out. Two styles on the symbol is what selects palette
    /// rendering, and losing the glyph one silently returns the transparent check (Sodalite#89). The
    /// glyph is the accent's foreground, not white, which vanished on Silver (Sodalite#207).
    @Test func theCheckIsPaletteRenderedWithAShadowAndNoTextStyle() throws {
        let badge = try source("Sodalite/Components/ArtworkStateBadges.swift")

        #expect(badge.contains("foregroundStyle(glyph, .tint)"))
        #expect(badge.contains("badge(\"checkmark.circle.fill\", glyph: appearanceTheme.palette.foreground.color)"))
        #expect(badge.contains(".shadow("))
        // A text style is what tied the old badge to Dynamic Type and to nothing else.
        #expect(!badge.contains(".font("))
    }

    private func source(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The inset was a fixed 10pt, which is 4.5 percent of a TV poster but 8.3 percent of a phone
    /// one, so the badge crowded the corner exactly where there was least room.
    @Test func theInsetIsTheSameFractionOnEveryTier() {
        let fractions = tiers.map { tier in
            PosterBadgeMetrics.checkInset(posterWidth: tier.metrics.posterSize.width, scale: 1)
                / tier.metrics.posterSize.width
        }

        #expect(Set(fractions).count == 1)
        #expect(fractions[0] >= 0.04 && fractions[0] <= 0.06)
    }

    /// It sits opposite the pills and must stay the larger of the two, else the state indicator
    /// reads as a footnote next to the resolution tag.
    @Test func theDiscIsLargerThanThePillTextBesideIt() {
        for tier in tiers {
            let width = tier.metrics.posterSize.width
            #expect(
                PosterBadgeMetrics.checkDiameter(posterWidth: width, scale: 1)
                    > PosterBadgeMetrics.fontSize(posterWidth: width, scale: 1)
            )
        }
    }
}

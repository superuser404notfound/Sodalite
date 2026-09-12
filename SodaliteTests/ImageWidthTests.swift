import Testing
import SwiftUI
@testable import Sodalite

/// Pins `ImageWidth` to the layout it is cut from (Sodalite#129). Every constant there is a
/// ceiling: the widest that family is ever rendered, across all three tiers, with Large Cards on.
/// The literals below are what ships, so a retune is a deliberate two-file edit; the derivations
/// under them are what makes a retuned card size fail here instead of quietly softening artwork on
/// a TV.
struct ImageWidthTests {

    private let tiers: [LayoutMetrics] = [.tv, .regular, .compact]

    /// Rendered points to requested pixels. `scaled` is on for the surfaces the Large Cards setting
    /// multiplies (`MediaCard`), off for the ones it does not touch (list rows, tiles, avatars).
    private func required(_ points: CGFloat, _ m: LayoutMetrics, scaled: Bool = false) -> Int {
        let cardScale = scaled ? AppearancePreferences.largeCardScale : 1
        return Int((points * m.screenScale * cardScale).rounded(.up))
    }

    @Test func shippedWidths() {
        #expect(ImageWidth.thumbnail == 320)
        #expect(ImageWidth.card == 640)
        #expect(ImageWidth.wideCard == 960)
        #expect(ImageWidth.cover == 960)
        #expect(ImageWidth.avatar == 480)
        #expect(ImageWidth.fullBleed == 1920)
        #expect(ImageWidth.topShelfCell == 1600)
    }

    @Test func cardCoversPosterAndSquareOnEveryTierAtLargeCards() {
        for m in tiers {
            #expect(ImageWidth.card >= required(m.posterSize.width, m, scaled: true))
            #expect(ImageWidth.card >= required(m.squareSize.width, m, scaled: true))
        }
    }

    /// The 16:9 family, and the widest requirement in the app: 360pt on tvOS, 1.3 for Large Cards,
    /// 2x for the panel. The tiles that do not scale (genre, library, provider, episode cards) are
    /// covered under it.
    @Test func wideCardCoversLandscapeOnEveryTierAtLargeCards() {
        for m in tiers {
            #expect(ImageWidth.wideCard >= required(m.landscapeSize.width, m, scaled: true))
        }
        #expect(ImageWidth.wideCard >= required(LayoutMetrics.tv.landscapeSize.width, .tv))
    }

    /// List rows take `listPosterSize` straight, without `cardScale`.
    @Test func thumbnailCoversListRows() {
        for m in tiers {
            #expect(ImageWidth.thumbnail >= required(m.listPosterSize.width, m))
        }
    }

    /// Profile cards, plus the person page's portrait, whose 140pt phone hero at 3x is the widest
    /// of the two and so the number `avatar` is cut to (`PersonDetailView.photoSide`).
    @Test func avatarCoversProfileCardsAndThePersonPortrait() {
        for m in tiers {
            #expect(ImageWidth.avatar >= required(m.profileCardSize.width, m))
        }
        #expect(ImageWidth.avatar >= required(140, .compact))
        #expect(ImageWidth.avatar >= required(200, .tv))
    }

    /// The music cover where it is the subject. `coverSide` compiles per platform, so this asserts
    /// whichever branch the test target built; the album header's cover (340pt, 220 compact) is
    /// smaller than both and rides under it.
    @Test func coverCoversTheNowPlayingCover() {
        #expect(ImageWidth.cover >= required(NowPlayingMetrics.coverSide(compact: false), .tv))
        #expect(ImageWidth.cover >= required(NowPlayingMetrics.coverSide(compact: true), .compact))
    }

    /// The order is the point: a family that reads bigger has to ask for more, and the full-bleed
    /// backdrop stays alone at the top because it is a source ceiling rather than a rendered size.
    @Test func familiesStayInOrder() {
        #expect(ImageWidth.thumbnail < ImageWidth.card)
        #expect(ImageWidth.card < ImageWidth.wideCard)
        #expect(ImageWidth.wideCard < ImageWidth.fullBleed)
        #expect(ImageWidth.cover >= ImageWidth.card)
    }

    /// The shelf asks for what the cell draws: about 800pt at 2x, measured off the screen rather
    /// than off Apple's documented 404pt, which tvOS 26 no longer matches. The burn-in decodes at
    /// this same width, so no cell on the shelf is softer than the one beside it (Sodalite#128).
    @Test func topShelfCoversTheCellItDraws() {
        #expect(ImageWidth.topShelfCell >= Int((800.0 * 2).rounded(.up)))
        #expect(ImageWidth.topShelfCell <= ImageWidth.fullBleed)
    }
}

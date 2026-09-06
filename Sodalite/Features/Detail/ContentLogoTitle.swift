import SwiftUI

/// Title-card logo for the detail screens. Renders the logo image at a two-axis budget when the item
/// has a Logo and logos are enabled; otherwise the caller's text-title fallback (so each surface
/// keeps its own styling).
struct ContentLogoTitle<Fallback: View>: View {

    /// Item that owns the logo; for episodes this is the SERIES item (no per-episode logo exists).
    let itemID: String
    /// True when the item's snapshot already carries a Logo tag. The slot then stays empty until the
    /// mark lands, instead of painting a text title that the mark replaces a moment later
    /// (Sodalite#97). False keeps the text: items without a logo, and the episode deep-link's series
    /// stub, which has no imageTags yet.
    var hasLogo: Bool = false
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @Environment(\.displayScale) private var displayScale

    /// The column the logo sits in. Layout runs before the image task, so this is measured before
    /// there is anything to draw; the tier nominal only ever covers the very first pass.
    @State private var columnWidth: CGFloat = 0
    /// Every candidate failed (offline blip, 404 on an item whose tag lied). Puts the text title
    /// back rather than leaving the page untitled.
    @State private var loadFailed = false

    private var tier: ContentLogoTier {
        #if os(tvOS)
        .tv
        #else
        ContentLogoTier.tier(
            isTV: false,
            compact: hSizeClass == .compact,
            // An unresolved first frame counts as portrait.
            portrait: vSizeClass != .compact
        )
        #endif
    }

    /// iPhone portrait centers the title to match the centered primary action button.
    private var isPhonePortrait: Bool { tier == .phonePortrait }

    /// tvOS draws its 1920x1080 point grid at 2x on the 4K box and reports no useful `displayScale`,
    /// so it asks for the same fixed 2x LayoutMetrics.castImageWidth assumes.
    private var pixelScale: CGFloat {
        #if os(tvOS)
        2
        #else
        displayScale
        #endif
    }

    /// Logo URL by item ID only: `/Items/{id}/Images/Logo` serves the current logo tagless, so it loads on the first frame from a series stub (episode deep-link) with no imageTags round-trip, and stays stable when the stub is replaced (no reload/flash). No-logo items 404 to the text fallback. nil only when logos are off.
    ///
    /// The pixel box is a constant per device family, never the measured column, the decoded aspect
    /// or the orientation: a URL that moves after the image lands re-fires AsyncCachedImage's
    /// `task(id:)` and flashes.
    private var logoURL: URL? {
        guard dependencies.appearancePreferences.showContentLogos else {
            return nil
        }
        let box = tier.requestPixels(scale: pixelScale)
        return dependencies.jellyfinImageService.imageURL(
            itemID: itemID,
            imageType: .logo,
            maxWidth: box.width,
            maxHeight: box.height
        )
    }

    /// Blank the placeholder only when a mark is actually on its way. With logos switched off there
    /// is no request at all, so the text has to paint on frame one.
    private var reservesSlotSilently: Bool {
        hasLogo && logoURL != nil && !loadFailed
    }

    var body: some View {
        let budget = tier.budget(columnWidth: columnWidth)
        // Always an AsyncCachedImage, never a branch: the fallback is its placeholder, so the stable per-id URL never swaps the subtree or resets `.id` to disturb the enclosing ScrollView.
        AsyncCachedImage(
            url: logoURL,
            onLoadFailed: { loadFailed = $0 },
            // sizedContent, not onImageLoaded: the mark's own size arrives WITH the mark, out of one
            // state, so there is no pass where an image is on screen and its aspect is not known yet.
            // Through the callback there was, and every first open drew the mark square (Sodalite#97).
            sizedContent: { image, imageSize in
                let drawn = ContentLogoSizing.size(
                    aspect: imageSize.width / imageSize.height,
                    in: budget
                )
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Both axes come from the budget, so the size is the tier's decision and not the
                    // source asset's aspect ratio (Sodalite#97).
                    .frame(width: drawn.width, height: drawn.height)
            }
        ) {
            if reservesSlotSilently {
                Color.clear
            } else {
                fallback()
                    .multilineTextAlignment(isPhonePortrait ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: isPhonePortrait ? .center : .leading)
            }
        }
        // Fixed-height slot, bottom-anchored: the mark and the text title share a baseline, so a
        // late-arriving logo cannot move the block's top edge (the pattern ExpandableTextBoxPlaceholder
        // uses for the overview, Sodalite#15). Also the thing that measures the column.
        //
        // budget.maxHeight is the CEILING, what a 1:1 mark draws, not the nominal. Reserving it costs
        // no layout anywhere: every tier hands the hero to an OVERLAY in a fixed band (200pt gradient
        // on tvOS/iPad/landscape, the artwork band in portrait), and an overlay does not size its
        // parent. A tall mark simply grows up into the backdrop, which is where the hero already
        // floats, and the panel below it does not move (rendered at 1920x1080, Sodalite#97 round 2).
        .frame(
            maxWidth: .infinity,
            minHeight: budget.maxHeight,
            maxHeight: budget.maxHeight,
            alignment: isPhonePortrait ? .bottom : .bottomLeading
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            columnWidth = width
        }
        // The glow still lifts a dark logo off a dark backdrop, but wide and soft instead of tight and
        // bright: at 0.45 over 6pt it drew a rim around the mark, which is what read as a halo
        // (Sodalite#97). Spreading the same lift over 16pt loses the rim and keeps the separation;
        // dropping it entirely does not, a black mark on a dark backdrop nearly disappears (measured
        // in an ImageRenderer sheet, 2026-09-01). The dark drop shadow does the opposite job, a light
        // mark on bright artwork.
        .shadow(color: .white.opacity(0.30), radius: 16)
        .shadow(color: .black.opacity(0.55), radius: 14, y: 4)
    }
}

/// Backdrop hero logo. Addressed by viewModel.item.id (the series id even for an episode-stub), so the logo loads on the first frame; reading viewModel.item keeps the text fallback in sync once the real name lands.
struct DetailHeroLogo: View {
    let viewModel: DetailViewModel

    var body: some View {
        ContentLogoTitle(
            itemID: viewModel.item.id,
            hasLogo: viewModel.item.imageTags?.logo != nil
        ) {
            Text(viewModel.item.name)
                .font(.largeTitle)
                .fontWeight(.bold)
        }
    }
}

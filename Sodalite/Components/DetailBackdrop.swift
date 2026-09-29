import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared fullscreen backdrop with gradient overlay used in all detail views.
///
/// tvOS, iPad and iPhone landscape only. iPhone portrait draws its hero as a 16:9 band inside the
/// scrolling `DetailContentOverlay` instead (Sodalite#95), so this fixed layer stands down there.
struct DetailBackdrop: View {
    let imageURL: URL?
    /// Hero stand-in for items lacking backdrop art: portrait poster scaled to screen width, top-pinned so its useful upper half stays on screen. Replaced the flat grey plate, then the heavy ambient blur-fill (Sodalite#15).
    var posterFallbackURL: URL? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    /// vSizeClass != .compact (rather than == .regular) treats the unresolved first frame as portrait.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    private var heroURL: URL? {
        imageURL ?? posterFallbackURL
    }

    /// Blur only the fallback poster (a portrait image upscaled into a landscape area). A real
    /// backdrop fills naturally and stays sharp.
    private var usesPosterFill: Bool {
        imageURL == nil && posterFallbackURL != nil
    }

    var body: some View {
        if isPhonePortrait {
            // The band lives in the scrolling overlay so page content can travel over it; a second
            // copy here would sit behind that content, fixed, and show through every gap.
            Color.clear
        } else {
            fixedBackdrop
        }
    }

    private var fixedBackdrop: some View {
        GeometryReader { geo in
            // Resolving here for the same reason the portrait band does it: this is the one view
            // that ever holds the decoded artwork, and the page below needs its colour (Sodalite#95,
            // extended to the other tiers in #146).
            AsyncCachedImage(url: heroURL, onImageLoaded: { image in
                #if canImport(UIKit)
                if let url = heroURL {
                    ArtworkTintStore.shared.resolve(image, for: url)
                }
                #endif
            }) { image in
                if usesPosterFill {
                    // Poster-as-hero: `.fill` scales to screen width, top-aligned to keep the useful upper half on screen. radius-8 blur (was 32 ambient, Sodalite#15) only smooths upscaling artefacts. drawingGroup bounds the blur to one Metal layer; an unbounded offscreen blur buffer broke detail-overlay sibling compositing on tvOS (glass panel + buttons vanished, nothing focusable, Back escaped the app).
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                        .blur(radius: 8)
                        .drawingGroup()
                } else {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } placeholder: {
                Rectangle().fill(Color.Theme.surface)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Light uniform dim for hero-text readability.
            .overlay(Color.black.opacity(0.15))
        }
    }
}

/// Scrollable content overlay fading transparent-to-opaque over the backdrop.
///
/// `hero` slot (title-card logo) floats on the artwork above the gradient, not the black panel, so dark logos stay legible (black on ultraThinMaterial would vanish). Empty default keeps no-hero overlays (collection, catalog) unchanged.
/// `primary` slot (glass panel + button row) makes the first screen one viewport tall with hero + panel + buttons bottom-aligned, maximizing visible backdrop (Sodalite#15 round 6). Empty default keeps the fixed 500 pt hero window for non-split overlays (collection, catalog, person).
struct DetailContentOverlay<Hero: View, Primary: View, Content: View>: View {
    /// Hero artwork for the iPhone-portrait band (ignored on every other tier, where the fixed
    /// `DetailBackdrop` owns the artwork). Same two URLs that surface passes to the backdrop.
    var heroImageURL: URL? = nil
    var heroPosterURL: URL? = nil
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let content: () -> Content

    /// Scroll-driven full-screen dim: 0 at top, ramps to 0.3 one hero-window deep, restoring readability over bright artwork without losing the full-bleed look.
    @State private var scrollDim: Double = 0

    /// tvOS fold marker state. The offset feeds off the same scroll-geometry hook as scrollDim.
    @State private var scrollOffset: CGFloat = 0
    /// iPhone portrait: whether the band has mostly left the top, so the system's soft top edge may
    /// blur what scrolls under the Dynamic Island and the close button (as on Home and the genre
    /// pages). Only there: landscape and iPad have no island for rows to run under.
    @State private var bandHasLeftTop = false
    /// Viewport height, which is also the first page's height (it is `containerRelativeFrame`).
    /// Read rather than assumed, so the pinned mark arrives with the fold on every tier.
    @State private var containerHeight: CGFloat = 0
    @State private var belowFoldHeight: CGFloat = 0
    @State private var hintSettled = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    /// Shorter clear hero window on a phone so content is reachable with one swipe.
    private var heroWindow: CGFloat { hSizeClass == .compact ? 320 : 500 }

    /// Everything past the content block is scroll the viewer can travel with nothing to see, and the
    /// filler used to be 600pt of it. On tvOS that is not just dead travel: the focus engine parks a
    /// focused row ~180pt above the bottom edge, but the LAST row can only get as far as the maximum
    /// scroll offset allows, so 680pt of trailing space (filler plus the 80pt padding) pinned a 400pt
    /// poster row 2pt below the top edge and clipped its focus scale and ring (Sodalite#52, measured
    /// in a tvOS focus probe). Keeping the trailing space near that ~180pt lands the last row where
    /// every other row lands. Shorter still on a phone, where the same filler was most of a screen.
    private var trailingFiller: CGFloat {
        hSizeClass == .compact ? 60 : 120
    }

    /// Whether there is anything below the fold yet, which is what decides whether the page offers
    /// any scroll travel at all (Sodalite#146 round 2).
    ///
    /// The padding and the filler below are for a settled page, where they keep the last row off the
    /// screen edge. Before the detail fetch lands there is no last row: the block measures zero, and
    /// those two are the only thing making the page scrollable, 200 pt of travel with nothing in it.
    /// Measured on a device: the page scrolled itself to 116 pt between 39 and 155 ms after opening,
    /// and every sample of that ramp reports `below fold 0`. The focus engine had landed on Play, it
    /// wanted the parking distance it always wants, and for once the page could give it: on a settled
    /// page the same request is already satisfied.
    ///
    /// So the fix is not to fight the scroll but to stop offering the room. With both gone while the
    /// block is empty the content is exactly one viewport, the page is not scrollable, and there is
    /// nothing to be dragged into. They come back with the content, by which time focus has long
    /// since settled and a focus change is what a scroll needs.
    ///
    /// No feedback loop: `belowFoldHeight` is measured on the block BEFORE either is applied.
    private var hasBelowFoldContent: Bool { belowFoldHeight > 0 }

    /// The reserved band and the hint itself are tvOS only: a scrollable page is self-evident on a
    /// touch device (Sodalite#53).
    private var reservesScrollHint: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var showsScrollHint: Bool {
        reservesScrollHint && ScrollHintPolicy.isVisible(
            scrollOffset: scrollOffset,
            belowFoldHeight: belowFoldHeight,
            hasSettled: hintSettled
        )
    }

    /// Per-side window safe-area insets, used to push only the CONTENT clear of the Dynamic Island while
    /// the backdrop + scrims stay full-bleed. Read from the window (the overlay is full-bleed, so the
    /// environment inset is gone). In landscape the island is on one side only, so only that side is
    /// inset and the island itself covers that margin; ~0 in portrait / iPad / tvOS (no change).
    private var safeLeading: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.left ?? 0
        #else
        0
        #endif
    }
    private var safeTrailing: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.right ?? 0
        #else
        0
        #endif
    }

    /// Picks the whole page shape, not a detail of one: portrait is a top-anchored 16:9 band with the
    /// content flowing beneath it, every other tier is a full-bleed backdrop with the first page
    /// bottom-aligned over it. vSizeClass != .compact treats the unresolved first frame as portrait.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    init(
        heroImageURL: URL? = nil,
        heroPosterURL: URL? = nil,
        @ViewBuilder hero: @escaping () -> Hero = { EmptyView() },
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.heroImageURL = heroImageURL
        self.heroPosterURL = heroPosterURL
        self.hero = hero
        self.primary = primary
        self.content = content
    }

    var body: some View {
        if isPhonePortrait {
            portraitBody
        } else {
            standardBody
        }
    }

    /// tvOS, iPad and iPhone landscape: the first page is one viewport tall with hero + panel +
    /// buttons bottom-aligned over the full-bleed backdrop, and every block carries its own scrim.
    private var standardBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if Primary.self == EmptyView.self {
                    Color.clear.frame(height: heroWindow)
                    gradientWithHero
                } else {
                    // First page one viewport tall, hero + primary bottom-aligned; the Spacer hands leftover space to the backdrop so the button row ends flush with the fold.
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        gradientWithHero
                        VStack(alignment: .leading, spacing: 0) {
                            primary()
                        }
                        // Inset the content past the island; the scrim (.frame + .background below)
                        // stays full-width, so no gray strip / backdrop margin appears.
                        .padding(.leading, safeLeading)
                        .padding(.trailing, safeTrailing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 24 pt matching the panel-to-buttons gap, widened on tvOS to a constant
                        // band that holds the fold marker (Sodalite#53).
                        .padding(.bottom, ScrollHintPolicy.primaryBottomInset(reservesHint: reservesScrollHint))
                        .overlay(alignment: .bottom) {
                            if reservesScrollHint {
                                ScrollHintChevron(isVisible: showsScrollHint)
                                    .padding(.bottom, 10)
                            }
                        }
                        .background(Color.Theme.scrim)
                    }
                    // iPhone landscape: do NOT force the first page to viewport height. In the short
                    // landscape viewport the content overflows, the panel scrim bleeds past the fold and
                    // overlaps the content-block scrim -> a doubled-up dark strip under the buttons that
                    // scrolls with the content. Sizing the block to its content keeps the scrims contiguous.
                    .modifier(FirstPageViewportHeight(active: vSizeClass != .compact))
                }

                // Content and filler under ONE ground, so the page colour runs to the bottom edge
                // instead of ending where the last row does.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 40) {
                        content()
                    }
                    // Height of the real below-fold content. The trailing filler below makes every
                    // page technically scrollable, so the hint keys off this instead (Sodalite#53).
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        belowFoldHeight = height
                    }
                    // Inset the content past the island; the ground stays full-width (no strip).
                    .padding(.leading, safeLeading)
                    .padding(.trailing, safeTrailing)
                    // Bound to the viewport, leading-aligned, so a wide child can't stretch the
                    // column past the screen and shove the whole content block off-center (section
                    // titles were being clipped on the left). Matches the primary slot's constraint.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, hasBelowFoldContent ? 80 : 0)

                    // Trailing filler so a short content block doesn't end in a hard edge; sized
                    // past any 4K tvOS safe-area inset.
                    //
                    // Removed rather than sized to zero when there is nothing below the fold. A
                    // `minHeight` caps nothing at the top end, and `Color` is infinitely flexible
                    // with an IDEAL size of 10x10, so in the unbounded height of a scroll view the
                    // zeroed filler still drew 10 pt. That is not a rounding error, it is scroll
                    // travel, and the focus engine took all ten of it: measured at exactly offset 10
                    // on a page that should not have been scrollable at all (Apple TV, 2026-09-15).
                    if hasBelowFoldContent {
                        Color.clear
                            .frame(minHeight: trailingFiller)
                            .overlay(alignment: .bottom) {
                                // Rubber-band overscroll pulls the content clear of the bottom edge
                                // and would uncover the bare backdrop there. This band hangs below
                                // the content end and scrolls with it, so it is off screen at rest
                                // and covers exactly the gap the bounce opens. An overlay on purpose:
                                // it carries no layout weight, so it adds no scroll travel of its
                                // own. Reading the overscroll from scroll geometry and sizing a fixed
                                // band instead does not work, the state update never reaches the
                                // overlay while the drag is in flight (measured, height stayed 0).
                                artworkPalette.far
                                    .frame(height: 600)
                                    .offset(y: 600)
                                    .allowsHitTesting(false)
                            }
                    }
                }
                .background(alignment: .top) { TuckGround(palette: artworkPalette) }
            }
        }
        .background(Color.black.opacity(scrollDim).ignoresSafeArea())
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Linear ramp over the clear hero window, capped at 0.3.
            scrollDim = min(max(offset / heroWindow, 0), 1) * 0.3
            scrollOffset = offset
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            containerHeight = height
        }
        // Hold the hint back through the cover's present transition, so a viewer who immediately
        // presses down never sees it appear.
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            hintSettled = true
        }
        // Where the page came to rest after opening (Sodalite#146 round 2). It is supposed to rest
        // at zero: the first page is exactly one viewport tall, so the fold sits on the screen's
        // bottom edge and nothing below it is in sight.
        //
        // Silent when that holds, which is what makes it worth keeping. Three separate causes were
        // found through this one line and every one of them was a page being offered scroll travel
        // it had no content for, so the next one will be too, and it will say so with the number
        // rather than with a report that it "sometimes looks wrong".
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard scrollOffset > ScrollHintPolicy.hideThreshold else { return }
            LogTap.shared.note(
                "detail: page settled at offset \(Int(scrollOffset.rounded())) "
                + "of viewport \(Int(containerHeight.rounded())), below fold \(Int(belowFoldHeight.rounded()))"
            )
        }
        // The colour arrives after the first paint (the artwork has to decode first), so it fades in
        // rather than switching.
        .animation(.easeInOut(duration: 0.4), value: artworkPalette)
    }

    // MARK: - iPhone portrait

    /// iPhone portrait (Sodalite#95): the artwork is a 16:9 band at its own aspect ratio, full-bleed
    /// to the top edge, and the page flows underneath it carrying a tint pulled from the band's own
    /// bottom pixels. It replaces the full-bleed portrait poster, which drew the show's baked-in
    /// title behind the overlaid logo, so every logo-bearing title rendered its name twice.
    ///
    /// The band scrolls with the content rather than sitting behind it: with the tint carrying the
    /// page, there is no scrim between the text and the artwork, so the artwork has to leave.
    private var portraitBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroBand

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        primary()
                    }
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 40) {
                        content()
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Keeps the last row off the screen edge. Transparent, unlike the scrimmed tiers:
                    // the tint canvas behind it already reaches the bottom. The hanging band carries
                    // the page colour into the rubber-band overscroll, which would otherwise uncover
                    // the black the detail views put under their ZStack.
                    Color.clear
                        .frame(minHeight: trailingFiller)
                        .overlay(alignment: .bottom) {
                            artworkPalette.far
                                .frame(height: 600)
                                .offset(y: 600)
                                .allowsHitTesting(false)
                        }
                }
                .background(alignment: .top) { tintCanvas }
            }
            // The mark rides over the page, not inside the band, and this is the only reason why.
            // Its dark shadow reaches about 18 pt past the ink (0.55 / r14 / y4), the tint canvas is
            // an OPAQUE sibling drawn after the band, so as a band overlay that tail was painted
            // over: the shadow ended in a single row exactly on the band's bottom bound, and that
            // line is what read as a hard cutoff on backdrops with a bright bottom edge (Sodalite#98
            // point 1). Measured on the reporter's screenshots: under the mark the last band row
            // runs 2.8 to 4.4 levels below the page margin and the next row matches it to within
            // 0.03, and the size of the step tracks the mark's own width (r = -0.93 across three
            // titles). Both sides of the seam are artworkPalette.near by construction, so the
            // shadow was the only thing that could draw a line there. Drawn last, it just fades out.
            .overlay(alignment: .top) {
                hero()
                    .padding(.horizontal, metrics.rowInset)
                    .frame(height: max(0, safeTop + bandHeight - 12), alignment: .bottom)
                    .allowsHitTesting(false)
            }
        }
        // Both edges: the band is the top chrome, and the canvas has to reach past the home indicator
        // or the page ends on a bright line where the scrim stops and the base black begins.
        .ignoresSafeArea(edges: [.top, .bottom])
        // iOS 26 lays its own effect over a scroll view's top edge, on top of the band, and it is a
        // separate thing from the navigation bar's background: hiding that background left the top of
        // the band black anyway on a PUSHED detail page (measured, Sodalite#95). So it stays off
        // while the band is up there, and comes on once the band has mostly scrolled away: from then
        // on the page's rows pass under the status bar and the close button, and they blur out there
        // like everywhere else instead of running under them sharp.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > bandHeight * 0.6
        } action: { _, hasLeft in
            bandHasLeftTop = hasLeft
        }
        .safeAreaBar(edge: .top) {
            // Only the height of the close button's row, for the edge effect to cover it too. The
            // page ignores the top safe area, so this moves nothing on it.
            Color.clear.frame(height: 56)
        }
        .scrollEdgeEffectHidden(!bandHasLeftTop, for: .top)
        .animation(.easeInOut(duration: 0.4), value: artworkPalette)
    }

    /// The band: the artwork's own top edge continued across the Dynamic Island, then the artwork.
    ///
    /// The artwork used to run to the top edge and the island sat on top of it (device, 2026-08-30).
    /// Insetting the artwork rather than shrinking it keeps it a true 16:9 rectangle, which was the
    /// point of the band; the page simply starts one safe area lower.
    private var heroBand: some View {
        VStack(spacing: 0) {
            islandStrip
            bandArtwork
        }
        // Dissolves the band into the page tint, so the artwork ends without an edge. Every stop is
        // the tint at a different opacity, never `.clear`: `.clear` is transparent BLACK, so fading
        // to it drags the artwork through a grey band on the way, which reads as the very edge this
        // is meant to remove. The eased stops and the 150 pt run are the second half of that; a
        // linear 96 pt ramp still showed the cut on a bright backdrop (device, 2026-08-30).
        .overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: artworkPalette.near.opacity(0), location: 0),
                    .init(color: artworkPalette.near.opacity(0.12), location: 0.30),
                    .init(color: artworkPalette.near.opacity(0.45), location: 0.58),
                    .init(color: artworkPalette.near.opacity(0.85), location: 0.82),
                    .init(color: artworkPalette.near, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 150)
            .allowsHitTesting(false)
        }
        // Rubber-band overscroll pulls the band down and would uncover the base black above it, the
        // same hole the trailing filler closes at the other end (Sodalite discussion #98, point 6).
        // The bounce itself stays: a scroll view that does not give is the odd thing on iOS, and the
        // complaint was the black it revealed, not the travel. Island colour, because that is what
        // the band's own top edge is made of.
        .overlay(alignment: .top) {
            artworkPalette.near
                .frame(height: 600)
                .offset(y: -600)
                .allowsHitTesting(false)
        }
    }

    /// Artwork for the band. A backdrop fills 16:9 exactly; a poster standing in for a missing
    /// backdrop keeps the established fallback treatment (filled to the width, pinned to its useful
    /// top half, blurred just enough to hide the upscale, bounded and flattened per the tvOS blur
    /// rule), which also stops its baked-in title from reading as a second logo.
    private var bandArtwork: some View {
        AsyncCachedImage(url: artworkURL, onImageLoaded: { image in
            #if canImport(UIKit)
            if let url = artworkURL {
                ArtworkTintStore.shared.resolve(image, for: url)
            }
            #endif
        }) { image in
            if portraitBandUsesPoster {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, minHeight: bandHeight, maxHeight: bandHeight, alignment: .top)
                    .clipped()
                    .blur(radius: 8)
                    .drawingGroup()
            } else {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, minHeight: bandHeight, maxHeight: bandHeight)
                    .clipped()
            }
        } placeholder: {
            Rectangle()
                .fill(Color.Theme.surface)
                .frame(maxWidth: .infinity, minHeight: bandHeight, maxHeight: bandHeight)
        }
        // Lets the artwork emerge out of the island strip's colour rather than start against it on a
        // line. Full opacity at the seam is what removes the edge; everything after that is only how
        // fast it lets go, and it has to let go quickly, or the veil reads as a haze lying over the
        // artwork rather than as its edge (Vincent, device, 2026-08-30). Half gone by 16 pt, four
        // fifths by 36, clear by 58, against 150 pt at the bottom, which has a whole page below it to
        // hand over to and can afford the slower curve.
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: artworkPalette.near, location: 0),
                    .init(color: artworkPalette.near.opacity(0.55), location: 0.20),
                    .init(color: artworkPalette.near.opacity(0.20), location: 0.45),
                    .init(color: artworkPalette.near.opacity(0.05), location: 0.72),
                    .init(color: artworkPalette.near.opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false)
        }
    }

    /// The strip behind the Dynamic Island: flat page colour. The whole top transition lives in the
    /// artwork's dissolve below it.
    ///
    /// Two cleverer strips were built and measured away first. A colour matched to the artwork's top
    /// edge (0.263 against 0.243 brightness) still read as a letterbox bar; the artwork's own top
    /// slice, mirrored and blurred, should have been seamless by construction and was worse. A
    /// SwiftUI `blur` fades a view's OWN EDGES into transparency, so the strip's last 14 pt pulled
    /// toward the black behind it. Measured across that seam: luminance 63 falling to 52, then
    /// jumping to 80 on the artwork's side, a 28-level step exactly where the mirror was meant to
    /// make the two continuous.
    ///
    /// The fault was never the strip's content, it was distance: 36 pt of transition at the top
    /// against 150 pt at the bottom. Flat colour and a long dissolve is what the bottom edge does,
    /// and it is what the top edge wanted (Vincent, device, 2026-08-30).
    private var islandStrip: some View {
        artworkPalette.near
            .frame(maxWidth: .infinity, minHeight: safeTop, maxHeight: safeTop)
    }

    /// The page colour, spanning the whole page rather than a fixed run that ends in black: the page
    /// keeps its colour all the way to the bottom, it only deepens (Vincent, 2026-08-30). Holding it
    /// flat over the first tenth keeps the action area looking like it carries the colour rather than
    /// like it is already losing it.
    private var tintCanvas: some View {
        LinearGradient(
            stops: [
                .init(color: artworkPalette.near, location: 0),
                .init(color: artworkPalette.near, location: 0.10),
                .init(color: artworkPalette.far, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var artworkURL: URL? {
        heroImageURL ?? heroPosterURL
    }

    private var portraitBandUsesPoster: Bool {
        heroImageURL == nil && heroPosterURL != nil
    }

    /// Base black until the artwork has been read, so an unresolved tint is invisible rather than a
    /// seam, and the real colour fades in when it lands.
    private var artworkPalette: ArtworkPalette {
        #if canImport(UIKit)
        ArtworkTintStore.shared.palette(for: artworkURL) ?? .base
        #else
        .base
        #endif
    }

    /// Height of the Dynamic Island / status bar region, which the band paints in the page colour.
    /// Read from the window for the same reason the side insets are: the overlay is full-bleed here,
    /// so the environment inset is gone by the time this is asked.
    private var safeTop: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top ?? 0
        #else
        return 0
        #endif
    }

    /// One clean 16:9 rectangle off the window width; the layout only ever supplies the width, so the
    /// height has to be derived rather than measured mid-flight.
    private var bandHeight: CGFloat {
        #if os(iOS)
        let width = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.bounds.width ?? 390
        return (width * 9 / 16).rounded()
        #else
        return 0
        #endif
    }

    // Hero rides as a gradient overlay (not a stacked layer) to keep the sibling structure the focus engine scrolls; drawn on top so the logo stays visible. Full-bleed redesign (Sodalite#15): backdrop stays behind a scrim, text containers carry their own material.
    private var gradientWithHero: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.35), .black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 200)
        .overlay(alignment: .bottomLeading) {
            hero()
                .padding(.horizontal, metrics.rowInset)
                .padding(.leading, safeLeading)
                .padding(.trailing, safeTrailing)
                .padding(.bottom, 8)
        }
    }
}

/// The ground under everything below the fold (Sodalite#146).
///
/// It used to be `Color.Theme.scrim`, black at 0.55, so the backdrop carried on behind the poster
/// rows and the cast circles at about a third of its luminance. On a bright, saturated backdrop that
/// is a colour cast over other titles' artwork, which is what "the fanart makes the lower rows hard
/// to read" means. The artwork hands over to a page ground at the fold instead.
///
/// The ground is the artwork's own colour, the same tint iPhone portrait paints below its band
/// (`ArtworkTint`, Sodalite#95), deepening down the page. A flat neutral was tried first and was the
/// safer answer on paper, since a 10-foot page below the fold is mostly OTHER titles' posters; it
/// went back out because the coloured page is what Vincent wanted on the screen (2026-09-14).
///
/// The handover band is the phone's own recipe, and every stop is the destination colour at a
/// different opacity, never `.clear`: `.clear` is transparent BLACK, so fading through it drags the
/// artwork across a grey band that reads as exactly the edge the dissolve exists to remove. The
/// eased stops and the 150 pt run are the second half of that, a linear 96 pt ramp still showed the
/// cut on a bright backdrop (device, 2026-08-30).
///
/// Nothing here is scroll-driven, and nothing needs to be: the band is part of the scrolling
/// content, so it tracks the finger and the remote one-to-one by construction and reverses exactly
/// on the way back up.
struct TuckGround: View {
    /// `.base` (black at both ends) until the artwork has been read, so an unresolved page is the
    /// black the detail views already put under their ZStack rather than a seam.
    let palette: ArtworkPalette

    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// How far the artwork takes to become the page. A floor rather than a measurement: the phone
    /// needed 150 pt on a far smaller screen, and the first tuck row peeks about that far above the
    /// fold, so the dissolve finishes where content starts.
    ///
    /// Shorter in a compact width, which here means iPhone LANDSCAPE (portrait draws its own band in
    /// `portraitBody` and never reaches this): 150 pt is most of a 390 pt landscape viewport, so the
    /// artwork would still be showing through under the whole first screen of rows.
    static func handoverHeight(compact: Bool) -> CGFloat { compact ? 100 : 150 }

    private var handover: CGFloat { Self.handoverHeight(compact: hSizeClass == .compact) }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: palette.near.opacity(0), location: 0),
                    .init(color: palette.near.opacity(0.12), location: 0.30),
                    .init(color: palette.near.opacity(0.45), location: 0.58),
                    .init(color: palette.near.opacity(0.85), location: 0.82),
                    .init(color: palette.near, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: handover)

            // The page keeps its colour all the way down, it only deepens. Held flat over the first
            // tenth so the row nearest the fold looks like it carries the colour rather than like it
            // is already losing it (Vincent, 2026-08-30).
            LinearGradient(
                stops: [
                    .init(color: palette.near, location: 0),
                    .init(color: palette.near, location: 0.10),
                    .init(color: palette.far, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Under the band, so its transparent half still carries the hero's own ground and the seam
        // at the fold has nothing to step over.
        .background(Color.Theme.scrim)
    }
}

/// Legacy shape for overlays without a `primary` slot (collection, catalog, person): fixed 500 pt hero window.
extension DetailContentOverlay where Primary == EmptyView {
    init(
        heroImageURL: URL? = nil,
        heroPosterURL: URL? = nil,
        @ViewBuilder hero: @escaping () -> Hero = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            heroImageURL: heroImageURL,
            heroPosterURL: heroPosterURL,
            hero: hero,
            primary: { EmptyView() },
            content: content
        )
    }
}

/// Applies `.containerRelativeFrame(.vertical)` only when active (everywhere except iPhone landscape),
/// so the viewport-tall first page is kept where there's room and dropped where it would overflow.
/// File-scoped (not nested in DetailContentOverlay) to avoid colliding with that type's `Content` param.
private struct FirstPageViewportHeight: ViewModifier {
    let active: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.containerRelativeFrame(.vertical)
        } else {
            content
        }
    }
}

/// Hands the detail page's vertical scroll proxy back to the view, iOS only.
///
/// The proxy has to be captured outside DetailContentOverlay to reach the glass panel; the reader
/// inside the content block only covers what sits below it. On tvOS this is a pass-through: the
/// focus engine already scrolls, and wrapping the overlay there would put a container into the tree
/// the focus picker walks for no gain.
struct PageScrollProxyCapture: ViewModifier {
    @Binding var proxy: ScrollViewProxy?

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        ScrollViewReader { pageProxy in
            content
                .onAppear { proxy = pageProxy }
        }
        #endif
    }
}

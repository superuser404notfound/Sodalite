import SwiftUI

struct GlassActionButton: View {
    @Environment(\.appearanceTheme) private var appearanceTheme

    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    /// Prominent variant wears destructive red instead of accent; non-prominent destructive stays neutral grey (role still applied for VoiceOver).
    var isDestructive: Bool = false
    /// Inline secondary label (e.g. resume "S1E5 · 12:34"); caption + 0.75 opacity so it reads as metadata, not a competing title.
    var subtitle: String? = nil
    /// 0…1 progress overlay behind the label (resume tile, accent fill); nil suppresses it.
    var progressFraction: Double? = nil
    /// Replaces the label with a spinner while the host resolves the play target (e.g. series play waits on getNextUp); quieter than flipping the title mid-render.
    var isLoading: Bool = false
    /// A disabled button leaves the focus engine, so on tvOS the row's auto-focus lands on the next button instead and a `@FocusState` push at that button is silently dropped. Set false where the button must keep focus through its loading spell; the host then has to make a press during loading meaningful.
    var disablesWhileLoading: Bool = true
    /// Keeps the label out of the row's icon-only collapse, for an action whose label IS its
    /// information where no focus exists to reveal it (the version button on a touch screen).
    var alwaysShowsLabel: Bool = false
    let action: () -> Void

    /// When set via `.collapsesActionButtonLabel(true)`, secondary buttons collapse to an icon-only pill revealing the title on focus, so a crowded row (Bluey: 8 actions) fits.
    @Environment(\.collapsesActionButtonLabel) private var collapsesLabel

    /// Everything drawn on the accent fill takes the accent's own foreground (Sodalite#111): white
    /// is only legible on a dark accent, and ten of the twenty-three presets are not dark. The
    /// destructive fill is red and the secondary fill is a dim white, so both stay white-labelled.
    private var contentColor: Color {
        isProminent && !isDestructive ? appearanceTheme.palette.foreground.color : .white
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil) {
            action()
        } label: {
            GlassActionButtonLabel(
                title: title,
                systemImage: systemImage,
                subtitle: subtitle,
                isProminent: isProminent,
                isLoading: isLoading,
                collapsesLabel: collapsesLabel && !alwaysShowsLabel,
                contentColor: contentColor
            )
        }
        .buttonStyle(GlassButtonStyle(
            isProminent: isProminent,
            isDestructive: isDestructive,
            progressFraction: progressFraction,
            contentColor: contentColor
        ))
        .disabled(isLoading && disablesWhileLoading)
        // Keep the title for VoiceOver even when the visible label collapses to an icon-only pill.
        .accessibilityLabel(Text(title))
    }
}

/// Own view so it can read `@Environment(\.isFocused)` from inside the button's subtree (same value GlassButtonStyle keys its ring off).
private struct GlassActionButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let subtitle: String?
    let isProminent: Bool
    let isLoading: Bool
    let collapsesLabel: Bool
    let contentColor: Color

    @Environment(\.isFocused) private var isFocused
    /// Measured intrinsic width of the trailing title/subtitle (leading gap baked in); the visible copy animates its frame 0→this so text fades in step with the growing width.
    @State private var labelWidth: CGFloat = 0

    /// Ceiling for the trailing subtitle. Resume stamps are a handful of digits, but the version
    /// button carries a label the SERVER writes (a media source name is a file name), and the tvOS
    /// action row is a plain HStack of fixed-size pills: it cannot scroll, wrap or compress, so an
    /// unbounded label walks the row off the screen. Measured in DetailActionRowWidthTests: a scene
    /// release name took the row to 2421 pt of the 1820 the title-safe width allows; at this ceiling
    /// it stays around 1440 (Sodalite#139).
    private static var subtitleCeiling: CGFloat {
        #if os(tvOS)
        500
        #else
        240
        #endif
    }

    /// Prominent buttons always show the title; secondary ones only when the row hasn't opted into collapsing, or while focused.
    private var showsLabel: Bool {
        !collapsesLabel || isProminent || isFocused
    }

    /// Falls back to `nil` (intrinsic) before measurement so the auto-focused Play button doesn't flash open from zero width.
    private var labelFrameWidth: CGFloat? {
        guard showsLabel else { return 0 }
        return labelWidth > 0 ? labelWidth : nil
    }

    /// Collapsible trailing content (title + optional subtitle); leading-glyph gap baked in so the measured width accounts for it.
    ///
    /// Baseline-aligned, not centred: the subtitle is two text styles smaller, and centring two
    /// boxes of different height puts the smaller one's baseline above the larger one's, which on
    /// the resume tile reads as the episode label floating.
    private var labelInner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(contentColor.opacity(0.75))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.subtitleCeiling, alignment: .leading)
            }
        }
        .padding(.leading, 10)
        .fixedSize()
    }

    var body: some View {
        HStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.body)
            }

            labelInner
                .frame(width: labelFrameWidth, alignment: .leading)
                .opacity(showsLabel ? 1 : 0)
                .clipped()
        }
        // Tighter padding for icon-only pills so they read as compact circles, not wide capsules.
        .padding(.horizontal, showsLabel ? 24 : 18)
        .padding(.vertical, 12)
        .fixedSize(horizontal: true, vertical: false)
        // Hidden full-size copy in a background (never stretches its primary) measures the true intrinsic width even while the visible copy is clipped to zero.
        .background(alignment: .leading) {
            labelInner
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: ActionLabelWidthKey.self, value: geo.size.width
                    )
                })
        }
        .onPreferenceChange(ActionLabelWidthKey.self) { labelWidth = $0 }
        // Width reveal + padding shift are animated by the row's shared transaction (CollapsingActionRowModifier) so all siblings interpolate together; no per-button animation here.
    }
}

private struct ActionLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}



/// Applies the pill lift against the control's measured width, because the distance a scale moves
/// an edge depends on the width it is applied to. `scaleEffect` is a render-time transform, so the
/// measurement it feeds is the layout width and cannot chase its own tail.
private struct CappedPillLift: ViewModifier {
    let isFocused: Bool
    let isPressed: Bool
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PillWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(PillWidthKey.self) { width = $0 }
            .focusResponse(
                .pill.capped(toLift: GlassButtonStyle.liftCeiling, width: width),
                isFocused: isFocused,
                isPressed: isPressed,
                pressedScale: 0.95
            )
    }
}

private struct PillWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Collapse opt-in environment

private struct CollapsesActionButtonLabelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether secondary buttons in this subtree collapse to icon-only, revealing the title on focus; default false keeps always-labelled (sheets, one-offs).
    var collapsesActionButtonLabel: Bool {
        get { self[CollapsesActionButtonLabelKey.self] }
        set { self[CollapsesActionButtonLabelKey.self] = newValue }
    }
}

extension View {
    /// Opt this row into icon-only secondary buttons and animate its reflow on focus change.
    func collapsesActionButtonLabel(_ collapses: Bool = true) -> some View {
        modifier(CollapsingActionRowModifier(collapses: collapses))
    }
}

/// Forces a shared spring onto every transaction in the row so focus change + label reveal + all sibling shifts interpolate in one pass. `.transaction` (not preference-keyed `.animation(value:)`, which lagged a frame and let distant buttons snap) rides the focus change so the row reflows as a unit.
private struct CollapsingActionRowModifier: ViewModifier {
    let collapses: Bool
    /// Gates the forced animation off until the row has settled in. The transaction otherwise animates the row's FIRST layout too, which during a fullScreenCover present interpolated the buttons from their initial frame and read as a "fly in from the top". After settling, focus-change reflows animate as before.
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .environment(\.collapsesActionButtonLabel, collapses)
            .transaction { txn in
                txn.animation = settled ? .smooth(duration: 0.32) : nil
            }
            .onAppear {
                deferOnMain(by: 0.35) { settled = true }
            }
    }
}

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    /// With `isProminent`, makes the fill destructive red; non-prominent destructive stays grey (parent Button's role handles VoiceOver).
    var isDestructive: Bool = false
    /// 0…1 resume progress, drawn as the filled part of the pill itself; ignored when nil.
    var progressFraction: Double? = nil
    /// What the label, the glyph and the progress bar are painted in. Derived by the button from
    /// the accent, so this style never has to know which accent is in play.
    var contentColor: Color = .white
    @Environment(\.isFocused) private var isFocused

    /// The fill the label's contrast was measured against (Sodalite#113). Named so the test can
    /// composite the same values instead of copying two literals that would drift.
    static let restingFillOpacity: Double = 0.7
    static let focusedFillOpacity: Double = 0.9
    /// The watched part of a resume pill: the accent with nothing behind it. A third ground the
    /// label has to survive (Sodalite#146 round 3), so the contrast suite composites it too.
    static let watchedFillOpacity: Double = 1.0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(contentColor)
            .background(
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(backgroundFill)

                    if let fraction = progressFraction, fraction > 0 {
                        watchedPortion(fraction)
                    }
                }
            )
            // A resting edge on the secondary pills, which have no fill strong enough to draw one
            // for them. They float over a detail page's artwork, where an unfocused row of flat
            // 0.1 white reads as smudges rather than as controls (Sodalite#146 round 3, reported on
            // a television and an iPad). The prominent pill needs none: its accent IS the edge.
            //
            // `hairline` rather than `panelEdge` because of what is BEHIND it. The quiet edge is for
            // a panel whose ground the app draws; these sit on whatever the scraper found, so the
            // failure case is a dark pill on a dark frame, which is the case hairline is bright for.
            .overlay {
                if !isProminent {
                    Capsule().strokeBorder(Color.Theme.hairline, lineWidth: 1)
                }
            }
            .focusStroke(Capsule(), isFocused: isFocused)
            // The role's curve matches the label-reveal spring here, so scale, border and
            // icon->label expansion move together. Capped, and therefore measured: see liftCeiling.
            .modifier(CappedPillLift(isFocused: isFocused, isPressed: configuration.isPressed))
    }

    /// How far a pill may grow on one side when focus lifts it. `DetailActionRow` sets its buttons
    /// `spacing` apart, so a lift wider than that puts the focused control over its neighbour, and
    /// with a server-written label on one of them (Sodalite#139) no fixed scale can promise that.
    ///
    /// It used to be 14, two points under the row's 16, which is as much as the row can physically
    /// afford. Physically affording it is not the same as looking right (Sodalite#146 round 2,
    /// reported on a device): at 14 the focused Play button hangs 14 pt past the page's left margin,
    /// where the logo, the panel and every heading below line up, and the gap to its neighbour drops
    /// from 16 pt to 2. Worse, how much it drops depends on the pill: the cap only binds on the wide
    /// ones, so an icon pill ate 3 pt of the gap and Play ate 14, which is the "spacing is not
    /// consistent" in the report.
    ///
    /// At 4 the cap binds on every pill in the row that carries a label, so the lift is a DISTANCE
    /// rather than a percentage and the gap it leaves is the same 12 pt whichever control has focus.
    /// The gesture itself is carried by the ring and the fill either way; the scale is the smallest
    /// of the three. `DetailActionRowFocusLiftTests` holds the numbers together.
    static let liftCeiling: CGFloat = 4

    /// The watched part of the pill, drawn as the pill's own fill at full strength (Sodalite#146
    /// round 3). The bar this replaces was two rows of content in a one-row control: it reserved
    /// `barHeight + barGap` out of the label's block and lifted the label by half of that, so the
    /// one pill on the page that carries a meter sat its text 7 pt above every sibling's.
    ///
    /// An accent capsule filling the tile from the leading edge WAS tried once and went back out,
    /// because it put half the label on the accent and half on grey and no single label colour was
    /// right. The difference now is that both sides of the seam are the same hue at two levels, so
    /// the label never crosses a colour, and the levels are measured rather than picked: the derived
    /// foreground clears 3:1 on the composited fill from alpha 0.60 upwards (amber on black is the
    /// binding case), and this runs 0.70 to 1.00, inside that band on both sides.
    ///
    /// The unwatched part holds `restingFillOpacity` even under focus, which is the one place the
    /// prominent fill ignores focus. Otherwise the step would be 0.90 against 1.00 exactly when it
    /// matters: Play is auto-focused, so focused IS the page's resting state on tvOS.
    private func watchedPortion(_ fraction: Double) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(isDestructive
                      ? AnyShapeStyle(Color.Theme.destructive.opacity(Self.watchedFillOpacity))
                      : AnyShapeStyle(TintShapeStyle.tint.opacity(Self.watchedFillOpacity)))
                .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
                .frame(maxHeight: .infinity, alignment: .leading)
        }
        .clipShape(Capsule())
    }

    private var backgroundFill: AnyShapeStyle {
        if isProminent {
            // A pill carrying progress keeps the resting level on its unwatched part whatever focus
            // does, so the step stays the same size on the state the page actually rests in.
            let carriesProgress = (progressFraction ?? 0) > 0
            let alpha = (isFocused && !carriesProgress) ? Self.focusedFillOpacity : Self.restingFillOpacity
            if isDestructive {
                return AnyShapeStyle(Color.Theme.destructive.opacity(alpha))
            }
            return AnyShapeStyle(TintShapeStyle.tint.opacity(alpha))
        }
        // The tint arrives on focus as the ring, so this pair is the token set for a control whose
        // lift comes from the COLOUR: a brighter resting ground, a small step under focus. It used
        // to be a bare 0.1/0.2 white, which is both a wider step than the system asks for and the
        // literal the theme tokens exist to replace.
        return AnyShapeStyle(isFocused ? Color.Theme.focusFill : Color.Theme.restFillStrong)
    }
}

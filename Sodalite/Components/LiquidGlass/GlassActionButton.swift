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
                collapsesLabel: collapsesLabel,
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
    private var labelInner: some View {
        HStack(spacing: 8) {
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
    /// 0…1 resume progress, drawn as a bar along the bottom of the fill; ignored when nil.
    var progressFraction: Double? = nil
    /// What the label, the glyph and the progress bar are painted in. Derived by the button from
    /// the accent, so this style never has to know which accent is in play.
    var contentColor: Color = .white
    @Environment(\.isFocused) private var isFocused

    /// The fill the label's contrast was measured against (Sodalite#113). Named so the test can
    /// composite the same values instead of copying two literals that would drift.
    static let restingFillOpacity: Double = 0.7
    static let focusedFillOpacity: Double = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(contentColor)
            .background(
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(backgroundFill)

                    if let fraction = progressFraction, fraction > 0 {
                        progressBar(fraction)
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.95 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
            // Matches the label-reveal spring so scale, border and icon→label expansion move together.
            .animation(.smooth(duration: 0.32), value: isFocused)
    }

    /// Progress used to be an accent capsule filling the tile from the leading edge, which forced
    /// the tile to drop its accent fill (accent on accent does not read) and put half the label on
    /// the accent and half on grey, so no single label colour was right. Drawing it in the label's
    /// own colour instead means the tile keeps the prominent fill every other primary action wears,
    /// and the whole label sits on one known ground.
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            let height = max(4, geo.size.height * 0.08)
            Capsule()
                .fill(contentColor.opacity(0.28))
                .frame(height: height)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(contentColor)
                        .frame(
                            width: (geo.size.width - Self.barInset * 2) * CGFloat(min(1.0, max(0, fraction))),
                            height: height
                        )
                }
                .padding(.horizontal, Self.barInset)
                .position(x: geo.size.width / 2, y: geo.size.height - height * 2)
        }
    }

    /// Lines the bar up with the label's own leading edge rather than the capsule's.
    private static let barInset: CGFloat = 24

    private var backgroundFill: AnyShapeStyle {
        if isProminent {
            if isDestructive {
                return AnyShapeStyle(Color.Theme.destructive.opacity(isFocused ? Self.focusedFillOpacity : Self.restingFillOpacity))
            }
            return AnyShapeStyle(TintShapeStyle.tint.opacity(isFocused ? Self.focusedFillOpacity : Self.restingFillOpacity))
        }
        return AnyShapeStyle(.white.opacity(isFocused ? 0.2 : 0.1))
    }
}

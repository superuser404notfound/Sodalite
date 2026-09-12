import SwiftUI
import UIKit

// MARK: - SwiftUI content

/// One program block. Focus fills tinted with black text, the app's convention for a focused
/// surface (see PopoverActionButton); an airing program keeps a tinted outline while unfocused so
/// the live column reads at a glance.
///
/// Title only (#137). The block used to carry "8:15 PM - 9:45 PM" under the title, a line the ruler
/// above and the block's own left edge already state. The window is spelled out where it is asked
/// for instead: the hero strip carries it for whatever is focused, the info panel for whatever is
/// opened. The title takes the freed line, so a long name wraps where it used to be scaled down and
/// cut.
struct GuideProgramCellContent: View {
    let title: String
    let isAiring: Bool
    let hasTimer: Bool
    let isFocused: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if hasTimer {
                Circle().fill(Color.Theme.recording).frame(width: 10, height: 10)
            }
            titleLabel
                .foregroundStyle(isFocused ? Color.black : Color.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFocused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.Theme.surfaceElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isAiring ? tint : Color.Theme.panelEdge,
                              lineWidth: isAiring ? 2 : 1)
        )
        .padding(EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2))
        // A three-minute program is a cell a few points wide. Clipping beats letting the label push
        // the block's own geometry around.
        .clipped()
    }

    /// Two sizes, never a continuum (#137 round 2). This used to be `minimumScaleFactor(0.85)`,
    /// which is not a second size but a floor: SwiftUI shrinks each cell by whatever fraction makes
    /// it fit, and it does that per cell, so the band from 32.3 to 38pt was open and a sample row
    /// measured three line pitches in it. Two neighbours with the same line count sat at different
    /// sizes, and since the type moves the baselines with it, at different apparent padding. The
    /// floor also failed at its own job, a title too long even at 0.85 coming back shrunk AND cut.
    ///
    /// The step keeps the weight (headline is semibold) so that it reads as the same label one size
    /// down rather than as a different kind of text.
    ///
    /// The first branch carries no `lineLimit` on purpose: that is the measurement. A clamped label
    /// reports the height of its clamp rather than of its text, so it always "fits" and the step
    /// never engages. Unclamped, it is chosen exactly when the title wraps inside the row (one or
    /// two headline lines), and a longer title falls to the step below, where it truncates.
    @ViewBuilder private var titleLabel: some View {
        ViewThatFits(in: .vertical) {
            Text(title).font(.headline)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
        }
    }
}

/// Channel column cell. Card-shaped, so it takes the semantic focus ring rather than the program
/// block's tint fill.
/// Focus fills tinted with black text, the same convention as a program block. It used to draw a
/// rectangular focus ring instead, which on a full-width row reads as two stray lines running across
/// the column rather than as a selection.
struct GuideChannelCellContent: View {
    let name: String
    let number: String?
    let logoURL: URL?
    let isFavorite: Bool
    let isFocused: Bool
    let tint: Color
    let metrics: GuideMetrics

    var body: some View {
        HStack(spacing: 10) {
            AsyncCachedImage(url: logoURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "tv")
                    .font(.system(size: metrics.channelLogoSize * 0.5))
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.black.opacity(0.4))
                                               : AnyShapeStyle(.tertiary))
            }
            .frame(width: metrics.channelLogoSize, height: metrics.channelLogoSize)

            nameBlock
                .frame(maxWidth: .infinity, alignment: .leading)
            if isFavorite {
                Image(systemName: "star.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isFocused ? Color.black : .yellow)
                    .frame(width: metrics.favoriteIconSize, height: metrics.favoriteIconSize)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isFocused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.Theme.surface))
    }

    /// The second line IPTV names need (they are suffixed "(1080p)" and similar, and one line at
    /// headline size cut them down to about six characters, 8ecf6f39), paid for this time.
    ///
    /// `lineLimit(2)` plus `minimumScaleFactor(0.8)` promised it and delivered neither half as soon
    /// as the channel carried a number, which is the normal case: two headline lines (90.70) over
    /// the number (29.83) want 122.53 of a 100pt row, and SwiftUI pays a vertical overflow with a
    /// TEXT LINE, so every long name came back on ONE truncated line ("Sky Sport Bun..."). The floor
    /// never engaged either, because a label shrinks only when shrinking makes it fit, and at a
    /// width that holds 13 characters it does not. With the number absent the two lines do appear,
    /// which is why this read as working.
    ///
    /// Stepped down the block measures 98.5 of the 100 hosted. The number moved from caption to
    /// caption2 to get there: at caption it came to 101 and spent the second line on the overflow
    /// again, one point short.
    @ViewBuilder private var nameBlock: some View {
        ViewThatFits(in: .vertical) {
            nameAndNumber(font: .headline, spacing: 2, lineLimit: nil)
                .fixedSize(horizontal: false, vertical: true)
            nameAndNumber(font: .subheadline.weight(.semibold), spacing: 0, lineLimit: 2)
        }
    }

    /// Two things make the measurement honest, and without either one the step never engages and
    /// the name silently truncates instead.
    ///
    /// The candidate is unclamped, because a label clamped to two lines reports the height of its
    /// clamp rather than of its text and therefore always fits. And it is fixed vertically, because
    /// a STACK asked for a height it cannot meet compresses its text instead and reports the height
    /// it was given: measured here, the block wants 167pt and answers "100" without it. A bare
    /// `Text` answers 136 and needs no such help, which is why the program block above has none.
    private func nameAndNumber(font: Font, spacing: CGFloat, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(name)
                .font(font)
                .lineLimit(lineLimit)
                .foregroundStyle(isFocused ? Color.black : Color.white)
            if let number {
                Text(number)
                    .font(.caption2)
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.black.opacity(0.7))
                                               : AnyShapeStyle(.secondary))
            }
        }
    }
}

/// One half-hour tick. Exactly one slot wide, so its edge meets the grid's line.
///
/// Passive: the ruler is not focusable. It was, on the theory that left and right on it would step
/// the axis in half hours, but reaching it means walking up through every channel row, so it was a
/// time control that disappeared exactly when the list got long enough to need one. Holding left or
/// right in the grid does the same job at finer granularity and from where the user already is.
struct GuideRulerCellContent: View {
    let label: String
    /// Prefixed on the first tick of a day, INLINE: stacked over the time it needed more than the
    /// 44pt ruler and both lines were clipped top and bottom.
    let dayLabel: String?

    var body: some View {
        Text(dayLabel.map { "\($0) \(label)" } ?? label)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }
}

// MARK: - UIKit hosts

/// `UIHostingConfiguration` creates a DETACHED SwiftUI hierarchy: nothing is inherited from the view
/// that hosts the controller. Without this injection AsyncCachedImage has no base URL and
/// MediaFocusRing draws the default accent instead of the user's.
private extension View {
    func guideCellEnvironment(_ dependencies: DependencyContainer,
                              _ theme: ResolvedAppearanceTheme) -> some View {
        environment(\.dependencies, dependencies)
            .environment(\.appearanceTheme, theme)
            // A cell overlapping the bottom safe area otherwise has its SwiftUI content squeezed by
            // exactly the overlapping part, so the last row rendered at half height with its rounded
            // bottom fully drawn instead of being cut by the viewport. Measured off a photo of the
            // device: 246px drawn where the row pitch was 446.
            .ignoresSafeArea()
    }
}

/// Cells must not inset themselves to the safe area either. `UITableView` exposes this as
/// `insetsContentViewsToSafeArea`; `UICollectionView` has no equivalent, so it is set per cell.
private func disableSafeAreaInsetting(_ cell: UICollectionViewCell) {
    cell.insetsLayoutMarginsFromSafeArea = false
    cell.contentView.insetsLayoutMarginsFromSafeArea = false
}

final class GuideProgramCell: UICollectionViewCell {
    static let reuseID = "GuideProgramCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        disableSafeAreaInsetting(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, isAiring: Bool, hasTimer: Bool, tint: Color,
                   dependencies: DependencyContainer, theme: ResolvedAppearanceTheme) {
        // configurationUpdateHandler reruns on every state change, which is how the focus fill
        // tracks without a manual didUpdateFocus override.
        configurationUpdateHandler = { cell, state in
            cell.contentConfiguration = UIHostingConfiguration {
                GuideProgramCellContent(
                    title: title, isAiring: isAiring, hasTimer: hasTimer,
                    isFocused: state.isFocused, tint: tint)
                    .guideCellEnvironment(dependencies, theme)
            }
            .margins(.all, 0)
        }
        setNeedsUpdateConfiguration()
    }
}

final class GuideChannelCell: UICollectionViewCell {
    static let reuseID = "GuideChannelCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        disableSafeAreaInsetting(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, number: String?, logoURL: URL?, isFavorite: Bool,
                   tint: Color, metrics: GuideMetrics, dependencies: DependencyContainer,
                   theme: ResolvedAppearanceTheme) {
        configurationUpdateHandler = { cell, state in
            cell.contentConfiguration = UIHostingConfiguration {
                GuideChannelCellContent(
                    name: name, number: number, logoURL: logoURL, isFavorite: isFavorite,
                    isFocused: state.isFocused, tint: tint, metrics: metrics)
                    .guideCellEnvironment(dependencies, theme)
            }
            .margins(.all, 0)
        }
        setNeedsUpdateConfiguration()
    }
}

final class GuideRulerCell: UICollectionViewCell {
    static let reuseID = "GuideRulerCell"

    override var canBecomeFocused: Bool { false }

    func configure(label: String, dayLabel: String?,
                   dependencies: DependencyContainer, theme: ResolvedAppearanceTheme) {
        contentConfiguration = UIHostingConfiguration {
            GuideRulerCellContent(label: label, dayLabel: dayLabel)
                .guideCellEnvironment(dependencies, theme)
        }
        .margins(.all, 0)
    }
}

// MARK: - Decorations

final class GuideNowLineView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemRed
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Half-hour vertical tick, drawn behind the cells (layout zIndex -1).
final class GuideGridLineView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

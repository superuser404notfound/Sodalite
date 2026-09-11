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
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
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

            VStack(alignment: .leading, spacing: 2) {
                // Two lines and a scale floor: IPTV providers suffix names with "(1080p)" and
                // similar, and one line at headline size truncated them to about six characters,
                // which made neighbouring channels indistinguishable on the device.
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isFocused ? Color.black : Color.white)
                if let number {
                    Text(number)
                        .font(.caption)
                        .foregroundStyle(isFocused ? AnyShapeStyle(Color.black.opacity(0.7))
                                                   : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
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

import SwiftUI

// MARK: - Dropdown Item


enum DropdownImage {
    case url(URL)                 // episode picker: Jellyfin image
    case chapterThumbnail(Int)    // chapter picker: server chapter image, else FrameExtractor still
}

struct DropdownItem {
    let title: String
    let isActive: Bool
    let isHighlighted: Bool
    /// Thumbnail source: `.url` (episodes), `.chapterThumbnail` (chapters), else nil.
    var image: DropdownImage? = nil
    /// Trailing affordance caption (e.g. "Hold to delete" on external subtitle rows).
    var hint: String? = nil
    /// Pins this row as a fixed footer below the scroll list (subtitle "Search online...").
    var isPinnedFooter: Bool = false
    var separatorAbove: Bool = false
    /// Pins this row as a fixed header above the scroll list (subtitle "Secondary: ...").
    var isPinnedHeader: Bool = false
    var separatorBelow: Bool = false
}

// MARK: - The chip

/// The chip both transport bars open their menu from. Shared so the live bar reads as the same
/// player as the VOD bar, which is what a viewer expects when only the content differs.
struct TransportTrackLabel: View {
    @Environment(\.appearanceTheme) private var appearanceTheme

    let label: String
    let icon: String
    let showsLabel: Bool
    let isFocused: Bool
    /// Replaces the leading glyph with the autoplay countdown ring (Sodalite#103). Sized to the
    /// glyph it stands in for, so the chip keeps the height of every other chip in the row.
    var countdownProgress: Double? = nil

    /// Measured intrinsic text width (leading gap baked in); the visible copy animates 0→this.
    @State private var labelWidth: CGFloat = 0

    private var labelFrameWidth: CGFloat? {
        guard showsLabel else { return 0 }
        return labelWidth > 0 ? labelWidth : nil
    }

    /// Collapsible trailing text, with the gap to the leading glyph baked into the measured width.
    private var labelInner: some View {
        Text(label)
            .font(.callout)
            // Single-line guarantee so an open dropdown's layout pressure can't break labels mid-word.
            .lineLimit(1)
            .padding(.leading, 8)
            .fixedSize()
    }

    var body: some View {
        HStack(spacing: 0) {
            if let countdownProgress {
                CountdownRingIcon(
                    progress: countdownProgress,
                    diameter: UIFont.preferredFont(forTextStyle: .callout).lineHeight)
            } else {
                Image(systemName: icon)
                    .font(.callout)
            }

            labelInner
                .frame(width: labelFrameWidth, alignment: .leading)
                .opacity(showsLabel ? 1 : 0)
                .clipped()
        }
        // Focused, the chip is a filled accent pill, so its glyph and label take the accent's own
        // paired foreground rather than white (Sodalite#124, the role pair Now Playing already uses).
        .foregroundStyle(isFocused
            ? AnyShapeStyle(appearanceTheme.palette.foreground.color)
            : AnyShapeStyle(.white.opacity(0.6)))
        // Tighter padding for icon-only pills so they read as compact squares, not empty capsules.
        .padding(.horizontal, showsLabel ? 16 : 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        // Hidden full-size copy in a background (never stretches its primary) measures the true
        // intrinsic width even while the visible copy is clipped to zero.
        .background(alignment: .leading) {
            labelInner
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: TransportLabelWidthKey.self, value: geo.size.width
                    )
                })
        }
        .onPreferenceChange(TransportLabelWidthKey.self) { labelWidth = $0 }
        .background(
            RoundedRectangle(cornerRadius: 8)
                // Full strength, not a translucent accent: `foreground` is derived against the solid
                // fill, and over a bright video frame a see-through pill loses the 3:1 it guarantees.
                // No focus ring here, an accent stroke on an accent fill is invisible; the fill,
                // the scale step and the shadow carry the focus on their own.
                .fill(isFocused
                    ? AnyShapeStyle(appearanceTheme.palette.control.color)
                    : AnyShapeStyle(.clear))
        )
        .scaleEffect(isFocused ? 1.08 : 1.0)
        // Depth cue so the focused pill reads as raised, not just tinted.
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
        // Per-button focus animation; the enclosing row also forces this curve via a transaction
        // so every sibling interpolates together instead of distant pills snapping.
        .animation(.smooth(duration: 0.32), value: isFocused)
    }
}

struct TransportLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The open menu

/// The open track menu, shared by both transport bars (AE#359 follow-up). Extracted from
/// `TransportBar` verbatim so the VOD bar and the Live bar cannot drift apart in row height,
/// highlight, scroll centring or transition. The chip that opens it stays with each bar: their
/// button idioms differ on purpose, VOD chips against the live capsules.
struct PlayerTrackDropdownList: View {
    let items: [DropdownItem]
    /// Chapter rows load their still lazily. nil where no bar offers chapters (live).
    var chapterThumbnail: (@Sendable (Int) async -> CGImage?)?

    private static let dropdownItemHeight: CGFloat = 56
    /// Taller row for thumbnail dropdowns (120×68 image + 8pt breathing room); text-only stays 56.
    private static let episodeRowHeight: CGFloat = 84
    private static let dropdownMaxVisible: Int = 6

    var body: some View {
            let hasImages = items.contains(where: { $0.image != nil })
            let rowHeight = hasImages ? Self.episodeRowHeight : Self.dropdownItemHeight
            // Pinned header/footer rows render outside the scroll area so they stay visible;
            // original indices are preserved so the host-driven highlight math is unaffected.
            let indexed = Array(items.enumerated())
            let headerIndexed = indexed.filter { $0.element.isPinnedHeader }
            let scrollIndexed = indexed.filter { !$0.element.isPinnedFooter && !$0.element.isPinnedHeader }
            let pinnedIndexed = indexed.filter { $0.element.isPinnedFooter }
            let visibleCount = min(scrollIndexed.count, Self.dropdownMaxVisible)
            let height = CGFloat(visibleCount) * rowHeight

            VStack(spacing: 0) {
                ForEach(headerIndexed, id: \.offset) { idx, item in
                    dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                        .id(idx)
                    if item.separatorBelow {
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(scrollIndexed, id: \.offset) { idx, item in
                                dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                                    .id(idx)
                            }
                        }
                    }
                    .onAppear {
                        // Explicit first-render scroll; .onChange only fires on a CHANGE, not
                        // for the value the dropdown opened at, so without this the active row
                        // is offscreen (anchored at 0) until the user moves one step.
                        if let highlighted = scrollIndexed.first(where: { $0.element.isHighlighted })?.offset {
                            proxy.scrollTo(highlighted, anchor: .center)
                        }
                    }
                    .onChange(of: scrollIndexed.first(where: { $0.element.isHighlighted })?.offset) { _, highlighted in
                        if let highlighted {
                            withAnimation { proxy.scrollTo(highlighted, anchor: .center) }
                        }
                    }
                }
                .frame(height: height)

                ForEach(pinnedIndexed, id: \.offset) { idx, item in
                    if item.separatorAbove {
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                    dropdownRow(item: item, hasImages: hasImages, rowHeight: rowHeight)
                        .id(idx)
                }
            }
            // Image dropdowns get a tight width cap so long titles wrap instead of stretching
            // the column over the transport row; text-only ones get headroom so names like
            // "Deutsch · Dolby TrueHD 7.1" don't truncate.
            .frame(
                minWidth: hasImages ? 480 : 0,
                maxWidth: hasImages ? 720 : 800
            )
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func dropdownRow(item: DropdownItem, hasImages: Bool, rowHeight: CGFloat) -> some View {
        HStack(spacing: 14) {
            if hasImages {
                Group {
                    switch item.image {
                    case .url(let url):
                        AsyncCachedImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(Color.Theme.restFill)
                        }
                    case .chapterThumbnail(let index):
                        ChapterThumbnailView(index: index, load: chapterThumbnail ?? { _ in nil })
                    case .none:
                        Rectangle().fill(Color.Theme.restFill)
                    }
                }
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text(item.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer()

            if let hint = item.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(item.isHighlighted ? .white.opacity(0.7) : .white.opacity(0.4))
            }

            if item.isActive {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .fontWeight(.bold)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: rowHeight)
        .background(item.isHighlighted ? Color.white.opacity(0.25) : Color.clear)
        .foregroundStyle(item.isHighlighted ? .white : .white.opacity(0.8))
        // Glide the highlight between rows instead of snapping.
        .animation(.smooth(duration: 0.32), value: item.isHighlighted)
    }
}

// MARK: - Chapter Thumbnail View

/// Loads a chapter thumbnail on appear (server chapter image, else FrameExtractor still),
/// gray placeholder until ready. Lazy, so only visible rows load; both caches make repeats cheap.
private struct ChapterThumbnailView: View {
    let index: Int
    let load: @Sendable (Int) async -> CGImage?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.Theme.restFill)
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: index) {
            image = await load(index)
        }
    }
}

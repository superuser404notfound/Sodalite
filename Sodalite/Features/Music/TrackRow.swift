import SwiftUI

/// One track in a music list: the album tracklist and the album-less library's flat list share it.
struct TrackRow: View {
    let song: JellyfinItem
    /// The number in the left column, or nil for none. The caller decides: an album knows its own
    /// running order, a flat list of tracks from several albums would count 1, 1, 2, 3, 2.
    let number: Int?
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: hSizeClass == .compact ? 14 : 24) {
            Group {
                if isCurrent {
                    NowPlayingWaveIcon(isPlaying: isPlaying, font: .body)
                } else {
                    Text(number.map(String.init) ?? "")
                        .font(.body)
                        .foregroundStyle(focused ? .white : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: 40, alignment: .center)

            Text(song.name)
                .font(.body)
                .fontWeight(isCurrent ? .semibold : .medium)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let ticks = song.runTimeTicks,
               let formatted = ResumeTimeFormatter.format(ticks: ticks) {
                Text(formatted)
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, hSizeClass == .compact ? 16 : 28)
        .padding(.vertical, hSizeClass == .compact ? 12 : 18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint)
        )
        .focusStroke(cornerRadius: 16, isFocused: focused)
        .focusResponse(.row, isFocused: focused)
        .focusableSurface(true)
        .focused($focused)
        .stableTap(isFocused: focused) {
            onSelect()
        }
    }

    /// `.tint` and `Color` are different shape-style types; erase to AnyShapeStyle to pick in one expression.
    private var titleColor: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(focused ? Color.white : Color.primary)
    }
}

import SwiftUI

/// A labelled number tile in the stats count grid; focusable so the non-focusable header above the grid is reachable (scrollable into view) on tvOS.
struct StatTile: View {
    let icon: String
    let value: String
    let label: LocalizedStringKey

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.tint)
            Text(value)
                .font(.system(size: hSizeClass == .compact ? 26 : 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, hSizeClass == .compact ? 16 : 28)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused ? Color.Theme.focusFill : Color.white.opacity(0.05))
        )
        .focusStroke(cornerRadius: 16, isFocused: focused)
        .focusResponse(.tile.flat, isFocused: focused)
        #if os(tvOS)
        .focusableSurface(true)
        .focused($focused)
        #endif
    }
}

/// One genre row; `fraction` is the genre's share of the top genre (0...1) so the longest bar is full-width.
struct GenreBar: View {
    let name: String
    let count: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Theme.restFill)
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(8, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
        }
    }
}

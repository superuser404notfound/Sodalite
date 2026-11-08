import SwiftUI

/// A capsule filter choice, tinted when selected (request filters, collection Movies / Shows).
struct FilterChip: View {
    let title: LocalizedStringKey
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
            if let count {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isSelected
                ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.65))
                : AnyShapeStyle(Color.Theme.restFill))
        )
        .focusStroke(Capsule(), isFocused: focused)
        .focusResponse(.chip, isFocused: focused)
        .focusableSurface(true)
        .focused($focused)
        .stableTap(isFocused: focused) { action() }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

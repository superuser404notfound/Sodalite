import SwiftUI

/// The viewer's own rating (Sodalite#48): ten stars, one point each, stored in Jellyfin's
/// `UserData.Rating` on the 0 to 10 scale the server enforces. `onSelect` gets the new value, nil
/// for a cleared rating; dismissing without a choice leaves the rating as it was.
struct RatingPickerSheet: View {
    /// The rating in force. A fractional one written by another client (7.5) shows as written and
    /// lights the stars it rounds to.
    let rating: Double?
    let tintColor: Color
    /// The end-of-film prompt names the film, the detail page's own button does not need to.
    var title: String? = nil
    let onSelect: (Double?) -> Void

    private enum Slot: Hashable {
        case star(Int)
        case clear
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Slot?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isCompact: Bool { hSizeClass == .compact }

    private var focusedStar: Int? {
        if case .star(let value) = focused { return value }
        return nil
    }

    /// Focus previews the value it would set; with focus off the stars, the stored rating shows.
    private var shownValue: Double? {
        focusedStar.map(Double.init) ?? rating
    }

    var body: some View {
        VStack(spacing: isCompact ? 20 : 40) {
            VStack(spacing: isCompact ? 6 : 12) {
                Text("rating.title")
                    .font(isCompact ? .title3 : .title2)
                    .fontWeight(.semibold)
                if let title {
                    Text(title)
                        .font(isCompact ? .subheadline : .headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: isCompact ? 4 : 18) {
                ForEach(1...10, id: \.self) { value in
                    star(value)
                }
            }

            Text(shownValue.map(Self.label) ?? String(localized: "rating.none", defaultValue: "Not rated"))
                .font(isCompact ? .headline : .title3)
                .monospacedDigit()
                .foregroundStyle(shownValue == nil ? .secondary : .primary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: shownValue)

            if rating != nil {
                clearButton
            }
        }
        .padding(isCompact ? 24 : 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(.thinMaterial)
        .presentationDetents([.medium])
        #endif
        .onAppear { focused = .star(Self.initialStar(for: rating)) }
    }

    private func star(_ value: Int) -> some View {
        let isFocused = focusedStar == value
        let lit = Double(value) <= (shownValue ?? 0).rounded()
        let size: CGFloat = isCompact ? 26 : 56
        return Image(systemName: lit ? "star.fill" : "star")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(lit ? tintColor : Color.secondary)
            .frame(width: size + (isCompact ? 4 : 16), height: size + (isCompact ? 8 : 24))
            .scaleEffect(isFocused ? 1.25 : 1)
            .animation(.snappy(duration: 0.15), value: isFocused)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(Self.label(Double(value))))
            .accessibilityAddTraits(rating.map { $0.rounded() == Double(value) } == true ? [.isSelected] : [])
            .focusableSurface(true)
            .focused($focused, equals: .star(value))
            .stableTap(isFocused: isFocused) {
                onSelect(Double(value))
                dismiss()
            }
    }

    private var clearButton: some View {
        let isFocused = focused == .clear
        return Label("rating.clear", systemImage: "xmark")
            .font(.body.weight(.medium))
            .padding(.horizontal, isCompact ? 18 : 32)
            .padding(.vertical, isCompact ? 12 : 18)
            .background(
                Capsule().fill(isFocused ? Color.white : Color.Theme.restFill)
            )
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .focusableSurface(true)
            .focused($focused, equals: .clear)
            .stableTap(isFocused: isFocused) {
                onSelect(nil)
                dismiss()
            }
    }

    /// "8 / 10"; a fractional rating keeps its one decimal.
    static func label(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "rating.value \(number)")
    }

    /// Opens on the stored rating, or mid-scale for an unrated title, so either direction is a short way.
    static func initialStar(for rating: Double?) -> Int {
        guard let rating else { return 5 }
        return min(10, max(1, Int(rating.rounded())))
    }
}

/// Drives the rating panel via `.menuPresentation(item:)`, so the item it rates travels with it.
struct RatingPrompt: Identifiable {
    let id = UUID()
    let itemID: String
    /// Set for the end-of-film prompt, which names the film it asks about.
    var title: String? = nil
}

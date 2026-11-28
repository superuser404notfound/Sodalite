import SwiftUI

/// Focusable card avoiding tvOS's default white focus border; use instead of Button for media cards and settings tiles.
struct FocusableCard<Content: View>: View {
    /// Set on a card carrying a context menu, so the hold opens the menu and not the card (Sodalite#75).
    /// Declared before `action` so a call can set it and still pass the action as a trailing closure.
    var opensMenuOnHold = false
    let action: () -> Void
    var highlightsOnPress = false
    var exposesButtonSemantics = false
    /// Caps the focus lift at this many points per side, for a card that can be far wider than a
    /// poster. At the `.card` scale a full-width collection banner grew 44 pt per side.
    var maxLiftPerSide: CGFloat?
    @ViewBuilder let content: (_ isFocused: Bool) -> Content

    @Environment(\.cardMenuWillOpen) private var cardMenuWillOpen
    @FocusState private var isFocused: Bool
    @GestureState private var isPressed = false

    @ViewBuilder
    var body: some View {
        if exposesButtonSemantics {
            pressAwareCard
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            pressAwareCard
        }
    }

    private var baseCard: some View {
        content(isHighlighted)
            .focusableSurface()
            .focused($isFocused)
            .stableTap(isFocused: isFocused, longPressOpensMenu: opensMenuOnHold, onHold: opensMenuOnHold ? cardMenuWillOpen : nil) { action() }
            .modifier(CardLift(maxLiftPerSide: maxLiftPerSide, isFocused: isHighlighted))
    }

    @ViewBuilder
    private var pressAwareCard: some View {
        #if os(iOS)
        if highlightsOnPress {
            baseCard.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { value, pressed, _ in
                        pressed = abs(value.translation.width) <= 24
                            && abs(value.translation.height) <= 24
                    }
            )
        } else {
            baseCard
        }
        #else
        baseCard
        #endif
    }

    private var isHighlighted: Bool {
        #if os(iOS)
        isFocused || (highlightsOnPress && isPressed)
        #else
        isFocused
        #endif
    }
}

/// The `.card` lift, capped against the measured width when the call site asks for it. Only capped
/// cards measure, so a grid of posters does not pay a geometry callback per cell.
private struct CardLift: ViewModifier {
    let maxLiftPerSide: CGFloat?
    let isFocused: Bool
    @State private var width: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maxLiftPerSide {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .focusResponse(.card.capped(toLift: maxLiftPerSide, width: width), isFocused: isFocused)
        } else {
            content.focusResponse(.card, isFocused: isFocused)
        }
    }
}

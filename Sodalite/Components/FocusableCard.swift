import SwiftUI

/// Focusable card avoiding tvOS's default white focus border; use instead of Button for media cards and settings tiles.
struct FocusableCard<Content: View>: View {
    /// Set on a card carrying a context menu, so the hold opens the menu and not the card (Sodalite#75).
    /// Declared before `action` so a call can set it and still pass the action as a trailing closure.
    var opensMenuOnHold = false
    let action: () -> Void
    var highlightsOnPress = false
    var exposesButtonSemantics = false
    @ViewBuilder let content: (_ isFocused: Bool) -> Content

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
            .stableTap(isFocused: isFocused, longPressOpensMenu: opensMenuOnHold) { action() }
            .focusResponse(.card, isFocused: isHighlighted)
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

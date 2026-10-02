import SwiftUI

/// Focusable-row activation gated on focus stability. Siri Remote finger drift in the last frames of a click can shift focus to a neighbour and activate the wrong tile; this drops presses until focus has been steady for `stableFocusWindow`. 80 ms is below human reaction to a focus shift (~200 ms) so it filters drift without latency on deliberate clicks. Caller still owns `.focusable`/`.focused` and styling.
struct StableTapModifier: ViewModifier {
    let isFocused: Bool
    /// Set on a row that also answers a hold (a `.contextMenu`). The press then decides on RELEASE and
    /// only counts as a click when it was shorter than the menu's own hold, so the row no longer acts
    /// on the way into its own menu (Sodalite#75). Off elsewhere: a row with nothing to disambiguate
    /// from keeps firing on the press itself, which is what makes the shell feel immediate.
    var longPressOpensMenu: Bool = false
    let action: () -> Void

    /// Minimum steady-focus time (s) before a press fires; drop to 0.06 if 80 ms feels sluggish.
    static let stableFocusWindow: TimeInterval = 0.08

    /// Longest press still read as a click on a row whose hold opens a menu. tvOS opens the menu at
    /// roughly half a second, and the two readings must not overlap: a press that reaches the menu has
    /// to leave with nothing else done. Under it rather than at it, so jitter falls on the safe side.
    static let clickHoldLimit: TimeInterval = 0.4

    @State private var focusAcquiredAt: Date?
    @State private var pressStartedAt: Date?
    /// Stability is judged when the press STARTS. Judging it at release would count the hold itself as
    /// steadiness and wave through exactly the drift this guards against.
    @State private var pressBeganOnStableFocus = false
    /// Set when the hold reached the limit. The gesture ends right there, and the end it reports measures
    /// against our own start stamp, which arrives a frame after the gesture's: that difference read a
    /// completed hold as a 0.39 s click often enough to open the row instead of its menu.
    @State private var holdReachedLimit = false

    func body(content: Content) -> some View {
        let tracked = content
            .onAppear {
                if isFocused { focusAcquiredAt = Date() }
            }
            .onChange(of: isFocused) { _, newValue in
                focusAcquiredAt = newValue ? Date() : nil
            }
        #if os(tvOS)
        return Group {
            if longPressOpensMenu {
                tracked.onLongPressGesture(minimumDuration: Self.clickHoldLimit) {
                    holdReachedLimit = true
                } onPressingChanged: { pressing in
                    if pressing {
                        pressStartedAt = Date()
                        pressBeganOnStableFocus = isFocusStable(at: Date())
                        holdReachedLimit = false
                    } else {
                        guard let started = pressStartedAt else { return }
                        pressStartedAt = nil
                        let duration = Date().timeIntervalSince(started)
                        let beganOnStableFocus = pressBeganOnStableFocus
                        // A completed hold reports its end and its completion in either order; the
                        // decision waits for both.
                        Task { @MainActor in
                            guard Self.isClick(
                                beganOnStableFocus: beganOnStableFocus,
                                pressDuration: duration,
                                holdReachedLimit: holdReachedLimit
                            ) else { return }
                            action()
                        }
                    }
                }
            } else {
                tracked.onLongPressGesture(minimumDuration: 0.01) { fireIfStable() }
            }
        }
        #else
        // iOS touch: fire immediately. The focus-stability gate guards Siri Remote finger
        // drift and is meaningless on touch (and would never fire: isFocused stays false
        // without a focus engine, so focusAcquiredAt is always nil). A long press belongs to
        // the row's context menu here too, and `.onTapGesture` already declines it.
        return tracked.onTapGesture { action() }
        #endif
    }

    private func isFocusStable(at moment: Date) -> Bool {
        guard let acquired = focusAcquiredAt else { return false }
        return moment.timeIntervalSince(acquired) >= Self.stableFocusWindow
    }

    private func fireIfStable() {
        if isFocusStable(at: Date()) { action() }
    }

    /// Whether a finished press activates the row: it has to have started on steady focus and to have
    /// ended before the menu's hold claims it. A hold the gesture saw complete never counts, whatever the
    /// measured duration says.
    static func isClick(
        beganOnStableFocus: Bool,
        pressDuration: TimeInterval,
        holdReachedLimit: Bool = false
    ) -> Bool {
        beganOnStableFocus && !holdReachedLimit && pressDuration < clickHoldLimit
    }
}

extension View {
    /// Stable-focus-gated tap; pass the row's `@FocusState`. Set `longPressOpensMenu` on a row that
    /// carries a `.contextMenu`. See `StableTapModifier` for rationale.
    func stableTap(
        isFocused: Bool,
        longPressOpensMenu: Bool = false,
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(StableTapModifier(
            isFocused: isFocused,
            longPressOpensMenu: longPressOpensMenu,
            action: action
        ))
    }
}

import SwiftUI

struct ThemeNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content().themedNavigationDestination()
        }
    }
}

struct ThemeNavigationPathStack<Content: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content().themedNavigationDestination()
        }
    }
}

extension View {
    /// Drops the system navigation bar's own background on iOS.
    ///
    /// A detail page owns its top edge: the hero band runs full bleed under the status bar. On a
    /// PUSHED detail (detail -> similar title -> person) a navigation bar exists, and it paints a
    /// background over exactly that region, so the band's top reads black instead of the page colour
    /// while the same page opened directly reads correctly (measured, Sodalite#95: (8,4,4) against
    /// the page's own (56,29,28), while an unpushed page matched at (61,50,57)). The bar keeps its
    /// controls, which carry their own glass and stay legible over artwork.
    @ViewBuilder
    func hidesToolbarBackground() -> some View {
        #if os(iOS)
        toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// For a tab page whose scroll view starts right under the iPhone's floating corner chrome
    /// (TabRootView.scrollsUnderChrome): the page itself reaches the top of the screen, and only the
    /// scroll CONTENT starts below the chrome, so rows scroll up through the band behind the badge
    /// and buttons and blur out there instead of being cut at a line.
    func scrollsUnderShellChrome() -> some View {
        modifier(ScrollsUnderShellChrome())
    }

    @ViewBuilder
    func themedNavigationDestination() -> some View {
        #if os(iOS)
        containerBackground(.clear, for: .navigation)
        #else
        self
        #endif
    }
}

// No-op-on-iOS shims for tvOS-only focus/command modifiers so shared views
// compile Universal. On tvOS the real modifier applies; on iOS the equivalent
// affordance comes from native touch navigation (back swipe / Now Playing remote)
// or is wired up in a later port phase. Keep call sites identical across platforms.
//
// onMoveCommand is also tvOS-only but carries real navigation behavior with no
// iOS analog yet, so it is gated inline with #if os(tvOS) at each site (replaced
// by touch controls in Phase 2) rather than silently no-op'd here.
extension View {
    /// tvOS focus section: a container the engine will move focus INTO even when no focusable view
    /// sits directly in the direction of travel. Every horizontally scrolling row wears one
    /// (Sodalite#80). Without it a vertical move resolves purely geometrically, so a row whose cards
    /// do not line up with the focused one is skipped, and where nothing lines up at all the move is
    /// refused and focus reads as frozen. Measured with XCUIRemote in a probe app: with one-item
    /// neighbour rows, up from the second My Media tile landed two rows away (`continueWatching-0`
    /// rather than the `nextUp-0` in between); with the section it lands on the row directly above,
    /// and layouts that already resolved correctly land on the same card either way.
    ///
    /// It does not change where INSIDE a row focus lands, which stays geometric (Sodalite#53).
    @ViewBuilder
    func focusSectionCompat() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func focusScopeCompat(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }

    @ViewBuilder
    func prefersDefaultFocusCompat(_ prefersDefaultFocus: Bool, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        #else
        self
        #endif
    }

    /// Hands focus back to a caller-chosen control when the viewer moves up out of this view.
    ///
    /// The focus engine resolves an up-move geometrically, from the centre of the view holding
    /// focus, and consults nothing else: a full-width element under a short left-aligned button
    /// row therefore lands on the row's LAST button, which on a detail page is Delete (Sodalite#53).
    /// Measured in a tvOS focus probe; .focusSection, a section on both sides of the boundary, and
    /// focusScope + prefersDefaultFocus all leave the landing unchanged, so the correction has to be
    /// explicit. The engine still moves first and this runs ~30ms behind it, which is why `action`
    /// must only hand focus somewhere, never act on it.
    ///
    /// Passing nil keeps stock navigation, so shared components stay unchanged for callers with no
    /// primary control to return to.
    @ViewBuilder
    func onFocusMoveUp(_ action: (() -> Void)?) -> some View {
        #if os(tvOS)
        if let action {
            onMoveCommand { direction in
                if direction == .up { action() }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Takes these controls out of the focus engine while focus sits below the fold, so an up-move
    /// out of the content has only the primary action left to land on and never touches the last
    /// button in the row (Sodalite#53). Correcting the landing afterwards also works, but the engine
    /// moves first and the button it passes through starts its 0.32s focus spring, which is visible
    /// as a twitch on Delete, more so while the page is still scrolling back.
    ///
    /// `.disabled` and not `.focusable(false)`: both keep focus off the button, but .focusable at any
    /// value collapses the row's sideways navigation (measured, five presses right never left Play),
    /// the same failure the picker in reference_tvos26_swiftui_owns_focus shows. With a custom
    /// ButtonStyle, disabling changes nothing visually, it reads isFocused and isPressed only.
    ///
    /// tvOS only, and deliberately so: on iOS these buttons are tapped, and disabling them would
    /// take the action away rather than a focus candidate.
    @ViewBuilder
    func focusSuppressed(_ suppressed: Bool) -> some View {
        #if os(tvOS)
        disabled(suppressed)
        #else
        self
        #endif
    }

    /// Same correction for one row of a ForEach: the modifier is applied unconditionally and the
    /// flag is checked inside, so row one keeps the exact view shape of its siblings. Branching the
    /// modifier itself hands the focus engine two different shapes in one list, which is what the
    /// value-based focus binding in CollectionDetailView already works around.
    @ViewBuilder
    func onFocusMoveUp(active: Bool, _ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onMoveCommand { direction in
            if direction == .up, active { action() }
        }
        #else
        self
        #endif
    }

    /// Applies .ignoresSafeArea only when `active`. Lets a detail screen stay full-bleed on
    /// tvOS/iPad while its scroll content respects the safe area on iPhone portrait (so the
    /// content is not clipped under the status bar / home indicator).
    @ViewBuilder
    func ignoresSafeArea(when active: Bool, edges: Edge.Set = .all) -> some View {
        if active {
            ignoresSafeArea(edges: edges)
        } else {
            self
        }
    }

    /// tvOS hides the navigation bar (it uses the Menu button to go back); iOS keeps the
    /// native bar so pushed screens get a back button and the interactive swipe-back gesture.
    @ViewBuilder
    func hidesNavigationBarChrome() -> some View {
        #if os(tvOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func onExitCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    /// Same, but installable and removable without changing the view's type. Passing nil to
    /// `onExitCommand` is what LEAVES the press to whoever is behind: an empty closure would still
    /// swallow it, and on a pushed screen that is the press meant to pop the screen (Sodalite#140).
    @ViewBuilder
    func onExitCommandIfEnabled(_ enabled: Bool, perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: enabled ? action : nil)
        #else
        self
        #endif
    }

    @ViewBuilder
    func onPlayPauseCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }

    /// Outer screen padding scaled by size class (tvOS 80/60, iPad 40/32, iPhone 16/16).
    /// Replaces the hardcoded tvOS 10-foot `.padding(.vertical, 60).padding(.horizontal, 80)`
    /// that starved content width on compact iPhone. tvOS resolves to the tv tier unchanged.
    func screenContentInset() -> some View { modifier(ScreenContentInset()) }
}

private struct ScreenContentInset: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading

    func body(content: Content) -> some View {
        let m = LayoutMetrics.current(hSizeClass)
        return content
            // The 80pt leading margin is for a shell whose navigation sits ABOVE the content. With
            // the sidebar beside it (Sodalite#140), the rail plus its gap is that margin, and
            // charging it twice pushes the first card a fifth of the screen inwards.
            //
            // Reduced, NOT removed: a focused row grows, and SwiftUI clips it at the container's
            // edge, so zero here cut the left side off the selected settings card.
            .padding(.leading, shellPaysLeading ? SidebarMetrics.contentLeading : m.screenHInset)
            .padding(.trailing, m.screenHInset)
            .padding(.vertical, m.screenVInset)
    }
}

private struct ShellPaysLeadingInsetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the sidebar shell on its content: the leading margin is already accounted for.
    var shellPaysLeadingInset: Bool {
        get { self[ShellPaysLeadingInsetKey.self] }
        set { self[ShellPaysLeadingInsetKey.self] = newValue }
    }
}

private struct ScrollsUnderShellChrome: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if hSizeClass == .compact {
            // An empty bar the height of the chrome: it insets the content, and it is what the
            // system's own scroll edge effect blurs under, which stays invisible while nothing is
            // beneath it (a material band of our own showed as a grey strip at rest).
            content
                .safeAreaBar(edge: .top) {
                    Color.clear.frame(height: TabRootView.gearChromeHeight)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

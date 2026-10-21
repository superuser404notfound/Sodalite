import SwiftUI

#if os(tvOS)

/// The tvOS navigation shell when the viewer keeps the top bar: the bar Sodalite draws itself, over
/// the selected tab's content. It does what the system `TabView` did, measured against it in the
/// tvOS 26 simulator, and only the bar's look changes:
///
/// - focus on a tab selects it, and an up-press from the content lands on the selected tab;
/// - the bar rides up with the page's scroll, one point per point, and comes back with it;
/// - a tab's page is built the first time it is selected and kept from then on, so walking the bar
///   does not rebuild what it passes, and a page keeps its scroll and its stack;
/// - Menu leaves the content for the bar, then the bar for Home, then the app (`SidebarExitPolicy`).
struct TopBarShell<Content: View>: View {
    let tabs: [AppTab]
    @Binding var selectedTab: AppTab
    @ViewBuilder let content: (AppTab) -> Content

    @FocusState private var focus: TopBarFocus?
    @Environment(\.resetFocus) private var resetFocus
    /// Mirrors the focus, so the Menu policy and the bar's offset can ask where it is without reading
    /// `@FocusState` mid-update.
    @State private var focusIsInBar = false
    @Namespace private var shellFocus
    /// Tabs whose page exists. A page is built on its first visit, the way `TabView` built it.
    @State private var builtTabs: Set<AppTab> = []
    /// Per tab, because each page asks for itself: a detail left open in one tab must not hide the
    /// bar over another.
    @State private var chromeHidden: [AppTab: Bool] = [:]
    @State private var scrollOffsets: [AppTab: CGFloat] = [:]

    private var selectedHidesChrome: Bool { chromeHidden[selectedTab] ?? false }

    private var exitOutcome: SidebarExitPolicy.Outcome {
        SidebarExitPolicy.next(focusIsInRail: focusIsInBar, selectedTab: selectedTab)
    }

    /// How far the scroll has carried the bar up. A focused bar is always fully down: Menu from a
    /// scrolled page brings the viewer to it, and it has to be there to be seen.
    private var barLift: CGFloat {
        guard !focusIsInBar else { return 0 }
        return min(max(scrollOffsets[selectedTab] ?? 0, 0), TopBarMetrics.travel)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(tabs.filter { builtTabs.contains($0) || $0 == selectedTab }, id: \.self) { tab in
                page(for: tab)
            }
        }
        .focusSectionCompat()
        .overlay(alignment: .top) {
            bar
                .padding(.top, TopBarMetrics.barTop)
                .offset(y: selectedHidesChrome ? -TopBarMetrics.travel : -barLift)
                .opacity(selectedHidesChrome ? 0 : 1)
                .disabled(selectedHidesChrome)
                .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: selectedHidesChrome)
                .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInBar)
                .ignoresSafeArea(edges: .top)
        }
        .onAppear { builtTabs.insert(selectedTab) }
        .onChange(of: selectedTab) { _, tab in
            builtTabs.insert(tab)
        }
        .onChange(of: tabs) { _, now in
            builtTabs.formIntersection(now)
        }
        .onChange(of: focus) { _, newValue in
            focusIsInBar = newValue != nil
            // Focus selects, as it did in the system bar.
            if case .item(let tab) = newValue, tab != selectedTab {
                selectedTab = tab
            }
        }
        // Menu is ours only while the bar is on screen and there is a step left in the chain; on the
        // last step the system's own handling has to see the press (see SidebarShell).
        .onExitCommandIfEnabled(!selectedHidesChrome && exitOutcome != .leaveApp) {
            switch exitOutcome {
            case .focusRail:
                focus = .item(selectedTab)
            case .selectHome:
                selectedTab = .home
                focus = .item(.home)
            case .leaveApp:
                break
            }
        }
        .focusScope(shellFocus)
    }

    private func page(for tab: AppTab) -> some View {
        let isSelected = tab == selectedTab
        return content(tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The room the bar takes, which the page's ROOT claims (see `reservesShellBar`).
            .environment(\.shellBarInset, TopBarMetrics.contentInset)
            .environment(\.shellBarScroll, ShellBarScroll { offset in
                scrollOffsets[tab] = offset
            })
            .onPreferenceChange(ShellChromeHiddenKey.self) { hidden in
                chromeHidden[tab] = hidden
            }
            // A kept page stays mounted but leaves the screen and the focus engine.
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            // The shell opens on the content, as it did under the system bar.
            .prefersDefaultFocus(isSelected, in: shellFocus)
    }

    private var bar: some View {
        HStack(spacing: TopBarMetrics.itemSpacing) {
            ForEach(tabs, id: \.self) { tab in
                TopBarItem(
                    tab: tab,
                    isSelected: tab == selectedTab,
                    barIsFocused: focusIsInBar,
                    focus: $focus,
                    onClick: {
                        // A click hands focus to the page under it. Clearing the binding alone left
                        // focus on the tab (measured); a reset in the shell's scope lands on the
                        // page that prefers default focus, which is the selected one.
                        resetFocus(in: shellFocus)
                    }
                )
            }
        }
        .padding(TopBarMetrics.panelPadding)
        // The same frosted dark the sidebar's rail sits on.
        .background(Capsule().fill(.regularMaterial))
        // One curve for everything the bar does, keyed on the focus too: the pill follows focus,
        // and keyed on the selection alone it jumped to the new tab a frame before the titles moved.
        .animation(.smooth(duration: 0.32), value: focus)
        .animation(.smooth(duration: 0.32), value: selectedTab)
        .animation(.smooth(duration: 0.32), value: focusIsInBar)
        // Screen-wide, like the system bar's frame: a focus section only catches a move whose path
        // crosses it, and an up-press from a card at the leading edge passes left of the capsule.
        .frame(maxWidth: .infinity)
        .focusSectionCompat()
    }
}
#endif

/// Hands a tab's root scroll offset to the top bar, which rides up with it.
struct ShellBarScroll {
    let report: (CGFloat) -> Void
}

extension EnvironmentValues {
    @Entry var shellBarScroll: ShellBarScroll?
    /// The room the top bar takes above a tab's root page, zero everywhere else. Claimed once, by
    /// the page's root, and zeroed for everything inside it, so a pushed screen, a sheet or a cover
    /// never inherits it.
    @Entry var shellBarInset: CGFloat = 0
}

extension View {
    /// Claims the top bar's room for a tab root that has no navigation stack of its own.
    /// `ThemeNavigationStack` does this for every root that has one: a safe-area inset applied
    /// OUTSIDE a navigation stack never reaches its root on tvOS, where the stack is UIKit (measured
    /// in the tvOS 26 simulator, the root page started at the top as if nothing were there).
    func reservesShellBar() -> some View {
        modifier(ReservesShellBar())
    }

    /// The inset itself, for a caller that read `shellBarInset` outside the content it pads.
    @ViewBuilder
    func shellBarInset(_ inset: CGFloat) -> some View {
        if inset > 0 {
            safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: inset)
            }
        } else {
            self
        }
    }

    /// Marks the scroll view the top bar rides with: a tab's ROOT page, the one under the bar. The
    /// system bar picked that scroll view by itself; a hand-drawn bar has to be told. A page that does
    /// not say keeps the bar in place, which costs nothing but the ride.
    func drivesShellBar() -> some View {
        modifier(DrivesShellBar())
    }
}

private struct ReservesShellBar: ViewModifier {
    @Environment(\.shellBarInset) private var inset

    func body(content: Content) -> some View {
        content
            .environment(\.shellBarInset, 0)
            .shellBarInset(inset)
    }
}

private struct DrivesShellBar: ViewModifier {
    @Environment(\.shellBarScroll) private var shellBarScroll

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            shellBarScroll?.report(offset)
        }
        #else
        content
        #endif
    }
}

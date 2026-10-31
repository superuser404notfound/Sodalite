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
    let tabs: [ShellTab]
    @Binding var selectedTab: ShellTab
    @ViewBuilder let content: (ShellTab) -> Content

    @FocusState private var focus: TopBarFocus?
    @Environment(\.resetFocus) private var resetFocus
    /// Mirrors the focus, so the Menu policy and the bar's offset can ask where it is without reading
    /// `@FocusState` mid-update.
    @State private var focusIsInBar = false
    @Namespace private var shellFocus
    /// Tabs whose page exists. A page is built on its first visit, the way `TabView` built it.
    @State private var builtTabs: Set<ShellTab> = []
    /// Per tab, because each page asks for itself: a detail left open in one tab must not hide the
    /// bar over another.
    @State private var chromeHidden: [ShellTab: Bool] = [:]
    /// Not `@State` values: a scroll writes here every frame, and only the bar may redraw for it.
    @State private var ride = ShellBarRide()
    /// Bumped per tab when Menu brings the viewer up to the bar, which the page answers by
    /// scrolling to its top (see `drivesShellBar`).
    @State private var scrollToTopRequests: [ShellTab: Int] = [:]
    /// The page on screen. It trails `selectedTab` by one update so the switch can run in an
    /// animation that knows its direction, including the first visit that builds the page.
    @State private var shownTab: ShellTab?
    /// Where the arriving page comes from, see `ShellPageSwitch`.
    @State private var switchDirection: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedHidesChrome: Bool { chromeHidden[selectedTab] ?? false }

    private var exitOutcome: SidebarExitPolicy.Outcome {
        SidebarExitPolicy.next(focusIsInRail: focusIsInBar, selectedTab: selectedTab)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(tabs.filter { builtTabs.contains($0) }, id: \.self) { tab in
                page(for: tab)
            }
        }
        .focusSectionCompat()
        .overlay(alignment: .top) {
            RidingBar(ride: ride, tab: selectedTab, isDown: focusIsInBar, isHidden: selectedHidesChrome) {
                bar
            }
                .padding(.top, TopBarMetrics.barTop)
                .opacity(selectedHidesChrome ? 0 : 1)
                .disabled(selectedHidesChrome)
                .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: selectedHidesChrome)
                .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInBar)
                .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            builtTabs.insert(selectedTab)
            shownTab = selectedTab
        }
        .onChange(of: selectedTab) { old, tab in
            switchDirection = ShellPageSwitch.direction(from: old, to: tab, in: tabs)
            withAnimation(Self.pageSwitch) {
                builtTabs.insert(tab)
                shownTab = tab
            }
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
                // The system bar scrolled the page back to its top here. Left where it was, the bar
                // came down over a page still scrolled deep into its rows.
                scrollToTopRequests[selectedTab, default: 0] += 1
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

    private func page(for tab: ShellTab) -> some View {
        let isSelected = tab == selectedTab
        let isShown = tab == shownTab
        return content(tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The room the bar takes, which the page's ROOT claims (see `reservesShellBar`).
            .environment(\.shellBarInset, TopBarMetrics.contentInset)
            .environment(\.shellBarScroll, ShellBarScroll(ride: ride, tab: tab))
            .environment(\.shellBarScrollToTop, scrollToTopRequests[tab] ?? 0)
            .onPreferenceChange(ShellChromeHiddenKey.self) { hidden in
                chromeHidden[tab] = hidden
            }
            // A kept page stays mounted but leaves the screen and the focus engine. It fades out
            // towards the side it lies on, and the arriving one fades in from the other.
            .opacity(isShown ? 1 : 0)
            .offset(x: slideDistance * ShellPageSwitch.restingSide(of: tab, shown: shownTab, in: tabs))
            .transition(.opacity.combined(with: .offset(x: slideDistance * switchDirection)))
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            // The shell opens on the content, as it did under the system bar.
            .prefersDefaultFocus(isSelected, in: shellFocus)
    }

    /// The bar's own curve, so the page and the pill moving over it arrive together.
    private static var pageSwitch: Animation { .smooth(duration: 0.32) }

    private var slideDistance: CGFloat {
        reduceMotion ? 0 : TopBarMetrics.pageSlide
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

/// The bar's ride, split from the shell so the page's scroll redraws the bar and nothing else. Read
/// in the shell's body, every scroll frame rebuilt the shell and with it every kept page.
private struct RidingBar<Bar: View>: View {
    let ride: ShellBarRide
    let tab: ShellTab
    /// A focused bar is always fully down: Menu from a scrolled page brings the viewer to it, and it
    /// has to be there to be seen.
    let isDown: Bool
    let isHidden: Bool
    @ViewBuilder let bar: Bar

    var body: some View {
        bar.offset(y: isHidden ? -TopBarMetrics.travel : (isDown ? 0 : -ride.lift(for: tab)))
    }
}
#endif

/// How far each tab's root scroll has carried the top bar up, clamped to the bar's travel. Only a
/// change inside that range is stored, so scrolling deeper than the bar can go costs nothing.
@MainActor @Observable
final class ShellBarRide {
    private var lifts: [ShellTab: CGFloat] = [:]

    func lift(for tab: ShellTab) -> CGFloat {
        lifts[tab] ?? 0
    }

    func report(_ offset: CGFloat, for tab: ShellTab) {
        let lift = min(max(offset, 0), TopBarMetrics.travel)
        if lifts[tab] != lift {
            lifts[tab] = lift
        }
    }
}

/// Hands a tab's root scroll offset to the top bar, which rides up with it. Equatable by identity,
/// so the environment value stays the same across the shell's updates and no page redraws for it.
struct ShellBarScroll: Equatable {
    let ride: ShellBarRide
    let tab: ShellTab

    @MainActor
    func report(_ offset: CGFloat) {
        ride.report(offset, for: tab)
    }

    static func == (lhs: ShellBarScroll, rhs: ShellBarScroll) -> Bool {
        lhs.ride === rhs.ride && lhs.tab == rhs.tab
    }
}

extension EnvironmentValues {
    @Entry var shellBarScroll: ShellBarScroll?
    /// Changes when the top bar asks the page under it to scroll back to its top.
    @Entry var shellBarScrollToTop = 0
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
    /// not say keeps the bar in place, which costs nothing but the ride. It is also the scroll view
    /// Menu sends back to the top.
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
    @Environment(\.shellBarScrollToTop) private var scrollToTop
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .scrollPosition($position)
            // Clamped here as well, so the action stops firing once the bar is fully up.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), TopBarMetrics.travel)
            } action: { _, offset in
                shellBarScroll?.report(offset)
            }
            .onChange(of: scrollToTop) {
                withAnimation(.easeOut(duration: 0.25)) {
                    position.scrollTo(edge: .top)
                }
            }
        #else
        content
        #endif
    }
}

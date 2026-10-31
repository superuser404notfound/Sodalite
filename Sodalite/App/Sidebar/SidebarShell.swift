#if os(tvOS)
import SwiftUI

/// Sodalite#140. The tvOS navigation shell when the viewer picked the sidebar: rail on the left,
/// the selected tab's content beside it. The rail PUSHES rather than covers, which is what lets it
/// carry the accent and what separates it from the system sidebar.
///
/// Walking the rail moves focus only. The content changes on Select, so running through seven tabs
/// costs no loads, and Live TV in particular is not woken up in passing.
///
/// A tab's page is built the first time it is selected and kept from then on, as the top bar keeps
/// it, so coming back to a tab reloads nothing and finds its stack as it was left. Its scroll does
/// not survive Select: focus released into a kept page goes to the top-leading card still partly on
/// screen and the page scrolls to it. Handing focus back to the card the viewer left needs
/// `UIFocusSystem.requestFocusUpdate(to:)`, which ignores an item outside the focused environment
/// (all measured in the tvOS 26 simulator).
struct SidebarShell<Content: View>: View {
    let tabs: [ShellTab]
    @Binding var selectedTab: ShellTab
    @ViewBuilder let content: (ShellTab) -> Content

    @FocusState private var focus: SidebarFocus?
    @Environment(\.resetFocus) private var resetFocus
    /// True while focus is anywhere inside the selected page (a container reports its descendants).
    @FocusState private var pageHoldsFocus: Bool
    /// The system places the opening focus without asking `prefersDefaultFocus`, top-leading first,
    /// and that is the rail's selected row (measured in the tvOS simulator: the rail took focus under
    /// the splash while the banner's Play was already on screen; the top bar escapes only because
    /// Play lies left of it). Until the page has held focus once, focus arriving in the rail is that
    /// placement and not the viewer, so it is handed back once.
    @State private var pageHasHeldFocus = false
    @State private var openingFocusHandedBack = false
    /// Mirrors the focus so the animation has something to compare, and so the Menu policy can ask
    /// where focus is without reading `@FocusState` mid-update.
    /// Starts false: the app opens on the content, the way it does with the top bar.
    @State private var focusIsInRail = false
    @Namespace private var shellFocus
    /// Raised by a pushed screen that wants the navigation out of the way (Settings sub-screens,
    /// the licence reader, Home's customiser). The rail then has to go, but NOT by taking a
    /// different branch: that rebuilds the content and the pushed screen's own stack goes with it.
    /// Per tab, because pages are kept: a detail left open in one tab must not hide the rail over
    /// another.
    @State private var chromeHidden: [ShellTab: Bool] = [:]
    /// Tabs whose page exists. A page is built on its first visit.
    @State private var builtTabs: Set<ShellTab> = []
    /// The page on screen, trailing `selectedTab` by one update so the switch animates with a
    /// direction (see TopBarShell).
    @State private var shownTab: ShellTab?
    /// Where the arriving page comes from, see `ShellPageSwitch`.
    @State private var switchDirection: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedHidesChrome: Bool { chromeHidden[selectedTab] ?? false }

    /// What the rail occupies in the layout. Note what it does NOT depend on: `chromeHidden`.
    ///
    /// A pushed screen takes the rail away but leaves the layout alone, so the content never moves
    /// for it. Every attempt at moving it fought the NavigationStack's own push and pop animation,
    /// two movements that know nothing about each other, and the result read as unrest no matter
    /// how the width was animated (a stack is UIKit-backed on tvOS and will not interpolate one
    /// anyway). One element moving beats two moving out of step.
    private var slotWidth: CGFloat {
        SidebarMetrics.railLeadingInset + SidebarMetrics.panelWidth(isExpanded: focusIsInRail)
    }

    /// Tabs whose page runs full width under the rail and insets its own content by the slot
    /// (`shellLeadingSlot`): Home, whose banner art fills the screen. Placed beside the rail instead,
    /// the art was cut at the slot, by the tab's NavigationStack, which on tvOS is UIKit and clips.
    static var fullBleedTabs: Set<ShellTab> { [.home] }

    private var exitOutcome: SidebarExitPolicy.Outcome {
        SidebarExitPolicy.next(focusIsInRail: focusIsInRail, selectedTab: selectedTab)
    }

    var body: some View {
        ZStack {
            ForEach(tabs.filter { builtTabs.contains($0) }, id: \.self) { tab in
                page(for: tab)
            }
        }
        .focused($pageHoldsFocus)
        .overlay(alignment: .leading) {
            SidebarRail(
                tabs: tabs,
                selectedTab: selectedTab,
                isExpanded: focusIsInRail,
                focus: $focus,
                onSelect: { tab in
                    // Select commits the tab and hands focus back to the content, so the rail
                    // collapses in the same gesture.
                    selectedTab = tab
                    focus = nil
                }
            )
            // Right always leaves for the page, as it does from the system sidebar. A move only
            // goes where something focusable lies in its path, and beside a row there is often
            // nothing: Home's banner runs under the rail, so Right from Home went nowhere (seen on
            // device, and the same before pages were kept). On the rail, never on a row: beside a
            // row's `stableTap` it costs Select presses (see `StableTapModifier`).
            .onMoveCommand { direction in
                if direction == .right {
                    focus = nil
                }
            }
            .padding(.leading, SidebarMetrics.railLeadingInset)
            // The only thing that moves for a pushed screen.
            .offset(x: selectedHidesChrome ? -SidebarMetrics.railSlot : 0)
            .opacity(selectedHidesChrome ? 0 : 1)
            .disabled(selectedHidesChrome)
            .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: selectedHidesChrome)
        }
        // ONE opt-out, for the whole shell. On a child alone it does not work: the HStack still
        // starts inside the 60pt title-safe margin, so the rail reaches the edge while the content
        // begins 60pt further right, and the two gaps around the rail can never match. Measured in
        // the simulator: 38pt on the left against 120 on the right.
        .ignoresSafeArea(edges: .leading)
        .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInRail)

        .onAppear {
            builtTabs.insert(selectedTab)
            shownTab = selectedTab
        }
        .onChange(of: selectedTab) { old, tab in
            switchDirection = ShellPageSwitch.direction(from: old, to: tab, in: tabs)
            withAnimation(ShellPageSwitch.fadeIn) {
                builtTabs.insert(tab)
                shownTab = tab
            }
        }
        .onChange(of: tabs) { _, now in
            builtTabs.formIntersection(now)
        }
        .onChange(of: focus) { _, newValue in
            focusIsInRail = newValue != nil
            // A page with nothing focusable keeps the rail: the reset finds no other place.
            if newValue != nil, !pageHasHeldFocus, !openingFocusHandedBack {
                openingFocusHandedBack = true
                resetFocus(in: shellFocus)
            }
        }
        .onChange(of: pageHoldsFocus) { _, holds in
            if holds { pageHasHeldFocus = true }
        }
        // Menu is ours only while the rail is on screen and there is a step left in the chain. On a
        // pushed screen the navigation stack owns it, and on the last step the system does: any
        // installed handler swallows the press, even one that does nothing, so Menu on Home in the
        // rail never left the app. Hence the nil rather than an empty closure.
        .onExitCommandIfEnabled(!selectedHidesChrome && exitOutcome != .leaveApp) {
            switch exitOutcome {
            case .focusRail:
                focus = .item(selectedTab)
            case .selectHome:
                selectedTab = .home
                focus = .item(.home)
            case .leaveApp:
                // Unreachable: the handler is not installed for this step.
                break
            }
        }
        .focusScope(shellFocus)
    }

    private func page(for tab: ShellTab) -> some View {
        let isSelected = tab == selectedTab
        let isShown = tab == shownTab
        let isFullBleed = Self.fullBleedTabs.contains(tab)
        return HStack(spacing: 0) {
            // Layout placeholder only. The rail itself is an overlay, so it can move freely while
            // this width changes in one step underneath it.
            Color.clear
                .frame(width: isFullBleed ? 0 : slotWidth)
                .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInRail)

            content(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Unconditional: the margins stay put when the rail leaves, so a pushed screen
                // does not re-lay-out itself on the way in or out.
                .environment(\.shellPaysLeadingInset, true)
                .environment(\.shellLeadingSlot, isFullBleed ? slotWidth : 0)
                .focusSectionCompat()
                .onPreferenceChange(ShellChromeHiddenKey.self) { hidden in
                    chromeHidden[tab] = hidden
                }
        }
        // A kept page stays mounted but leaves the screen and the focus engine. Opacity and hit
        // testing alone leave its focus section in place, and a kept page stacked above the
        // selected one caught the move and found nothing in it: Down from Live TV's segments went
        // nowhere once Settings had been visited (Sodalite#140, reproduced in the tvOS simulator).
        // It fades out towards the side its row sits on, and the arriving one fades in from the other.
        .opacity(isShown ? 1 : 0)
        .offset(y: slideDistance * ShellPageSwitch.restingSide(of: tab, shown: shownTab, in: tabs))
        .transition(
            AnyTransition.opacity.combined(with: .offset(y: slideDistance * switchDirection))
                .animation(ShellPageSwitch.fadeIn)
        )
        .animation(ShellPageSwitch.animation(isShown: isShown), value: isShown)
        .allowsHitTesting(isSelected)
        .disabled(!isSelected)
        .accessibilityHidden(!isSelected)
        // The shell opens on the content, not on the rail, which is what the top bar does.
        .prefersDefaultFocus(isSelected, in: shellFocus)
    }

    private var slideDistance: CGFloat {
        reduceMotion ? 0 : SidebarMetrics.pageSlide
    }
}
#endif

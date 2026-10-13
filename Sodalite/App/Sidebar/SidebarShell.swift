#if os(tvOS)
import SwiftUI

/// Sodalite#140. The tvOS navigation shell when the viewer picked the sidebar: rail on the left,
/// the selected tab's content beside it. The rail PUSHES rather than covers, which is what lets it
/// carry the accent and what separates it from the system sidebar.
///
/// Walking the rail moves focus only. The content changes on Select, so running through seven tabs
/// costs no loads, and Live TV in particular is not woken up in passing.
struct SidebarShell<Content: View>: View {
    let tabs: [AppTab]
    @Binding var selectedTab: AppTab
    @ViewBuilder let content: (AppTab) -> Content

    @FocusState private var focus: SidebarFocus?
    /// Mirrors the focus so the animation has something to compare, and so the Menu policy can ask
    /// where focus is without reading `@FocusState` mid-update.
    /// Starts false: the app opens on the content, the way it does with the top bar.
    @State private var focusIsInRail = false
    @Namespace private var shellFocus
    /// Raised by a pushed screen that wants the navigation out of the way (Settings sub-screens,
    /// the licence reader, Home's customiser). The rail then has to go, but NOT by taking a
    /// different branch: that rebuilds the content and the pushed screen's own stack goes with it.
    @State private var chromeHidden = false

    /// What the rail occupies in the layout. Note what it does NOT depend on: `chromeHidden`.
    ///
    /// A pushed screen takes the rail away but leaves the layout alone, so the content never moves
    /// for it. Every attempt at moving it fought the NavigationStack's own push and pop animation,
    /// two movements that know nothing about each other, and the result read as unrest no matter
    /// how the width was animated (a stack is UIKit-backed on tvOS and will not interpolate one
    /// anyway). One element moving beats two moving out of step.
    private var slotWidth: CGFloat {
        SidebarMetrics.railLeadingInset + SidebarMetrics.width(isExpanded: focusIsInRail)
    }

    /// Tabs whose page runs full width under the rail and insets its own content by the slot
    /// (`shellLeadingSlot`): Home, whose banner art fills the screen. Placed beside the rail instead,
    /// the art was cut at the slot, by the tab's NavigationStack, which on tvOS is UIKit and clips.
    static var fullBleedTabs: Set<AppTab> { [.home] }

    private var isFullBleed: Bool { Self.fullBleedTabs.contains(selectedTab) }

    var body: some View {
        HStack(spacing: 0) {
            // Layout placeholder only. The rail itself is an overlay, so it can move freely while
            // this width changes in one step underneath it.
            Color.clear
                .frame(width: isFullBleed ? 0 : slotWidth)
                .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInRail)

            content(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Unconditional: the margins stay put when the rail leaves, so a pushed screen
                // does not re-lay-out itself on the way in or out.
                .environment(\.shellPaysLeadingInset, true)
                .environment(\.shellLeadingSlot, isFullBleed ? slotWidth : 0)
                .focusSectionCompat()
                // The shell opens on the content, not on the rail, which is what the top bar does.
                .prefersDefaultFocus(true, in: shellFocus)
                .onPreferenceChange(ShellChromeHiddenKey.self) { hidden in
                    chromeHidden = hidden
                }
        }
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
            .padding(.leading, SidebarMetrics.railLeadingInset)
            // The only thing that moves for a pushed screen.
            .offset(x: chromeHidden ? -SidebarMetrics.railSlot : 0)
            .opacity(chromeHidden ? 0 : 1)
            .disabled(chromeHidden)
            .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: chromeHidden)
        }
        // ONE opt-out, for the whole shell. On a child alone it does not work: the HStack still
        // starts inside the 60pt title-safe margin, so the rail reaches the edge while the content
        // begins 60pt further right, and the two gaps around the rail can never match. Measured in
        // the simulator: 38pt on the left against 120 on the right.
        .ignoresSafeArea(edges: .leading)
        .animation(.easeInOut(duration: SidebarMetrics.expandDuration), value: focusIsInRail)

        .onChange(of: focus) { _, newValue in
            focusIsInRail = newValue != nil
        }
        // Menu is ours only while the rail is on screen. On a pushed screen the navigation stack
        // owns it, and an installed handler would swallow the press that should pop the screen,
        // hence the nil rather than an empty closure.
        .onExitCommandIfEnabled(!chromeHidden) {
            switch SidebarExitPolicy.next(focusIsInRail: focusIsInRail, selectedTab: selectedTab) {
            case .focusRail:
                focus = .item(selectedTab)
            case .selectHome:
                selectedTab = .home
                focus = .item(.home)
            case .leaveApp:
                // Nothing: letting the press fall through is what leaves the app.
                break
            }
        }
        .focusScope(shellFocus)
    }
}
#endif

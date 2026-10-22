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
    /// Per tab, because pages are kept: a detail left open in one tab must not hide the rail over
    /// another.
    @State private var chromeHidden: [AppTab: Bool] = [:]
    /// Tabs whose page exists. A page is built on its first visit.
    @State private var builtTabs: Set<AppTab> = []

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
    static var fullBleedTabs: Set<AppTab> { [.home] }

    private var exitOutcome: SidebarExitPolicy.Outcome {
        SidebarExitPolicy.next(focusIsInRail: focusIsInRail, selectedTab: selectedTab)
    }

    var body: some View {
        ZStack {
            ForEach(tabs.filter { builtTabs.contains($0) || $0 == selectedTab }, id: \.self) { tab in
                page(for: tab)
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

        .onAppear { builtTabs.insert(selectedTab) }
        .onChange(of: selectedTab) { _, tab in
            builtTabs.insert(tab)
        }
        .onChange(of: tabs) { _, now in
            builtTabs.formIntersection(now)
        }
        .onChange(of: focus) { _, newValue in
            focusIsInRail = newValue != nil
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

    private func page(for tab: AppTab) -> some View {
        let isSelected = tab == selectedTab
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
        // A kept page stays mounted but leaves the screen and the focus engine.
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
        // The shell opens on the content, not on the rail, which is what the top bar does.
        .prefersDefaultFocus(isSelected, in: shellFocus)
    }
}
#endif

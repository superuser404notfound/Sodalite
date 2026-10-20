#if os(tvOS)
import SwiftUI

/// Sodalite#140. The rail. Vertically centred as one block rather than starting at the top, which
/// reads cleaner on a TV and keeps the icons near the eye line whatever the tab count.
///
/// Settings sits below a divider because it is not a browsing destination. In the collapsed rail
/// that divider shrinks to the icon column, otherwise it draws a line across empty space.
struct SidebarRail: View {
    let tabs: [AppTab]
    let selectedTab: AppTab
    let isExpanded: Bool
    @FocusState.Binding var focus: SidebarFocus?
    let onSelect: (AppTab) -> Void

    /// Settings is pulled out of the flow above and placed under the divider.
    private var browsingTabs: [AppTab] { tabs.filter { $0 != .settings } }
    private var hasSettings: Bool { tabs.contains(.settings) }

    private var dividerWidth: CGFloat {
        isExpanded ? SidebarMetrics.expandedWidth - SidebarMetrics.horizontalPadding * 2
                   : SidebarMetrics.iconColumn
    }

    var body: some View {
        VStack(alignment: isExpanded ? .leading : .center, spacing: SidebarMetrics.itemSpacing) {
            SidebarProfileHeader(isExpanded: isExpanded)

            ForEach(browsingTabs, id: \.self) { tab in
                SidebarItemRow(
                    tab: tab,
                    isSelected: tab == selectedTab,
                    isExpanded: isExpanded,
                    focus: $focus,
                    onSelect: { onSelect(tab) }
                )
            }

            if hasSettings {
                Rectangle()
                    .fill(Color.Theme.hairline)
                    .frame(width: dividerWidth, height: SidebarMetrics.dividerHeight)
                    // Centred in both states. The expanded rail aligns its rows leading, and the
                    // divider, shorter than the rail by the padding, followed them to the left.
                    .frame(maxWidth: .infinity)

                SidebarItemRow(
                    tab: .settings,
                    isSelected: selectedTab == .settings,
                    isExpanded: isExpanded,
                    focus: $focus,
                    onSelect: { onSelect(.settings) }
                )
            }
        }
        .frame(width: SidebarMetrics.width(isExpanded: isExpanded))
        // A glass panel behind the rail, the same frosted dark the top bar sits on. It was dropped
        // once, when the rail only ever lay over the app background and the icons were legible there
        // on their own; Home's banner now runs under the rail, and over bright artwork they were not.
        .padding(.vertical, SidebarMetrics.panelVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.panelCornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .frame(maxHeight: .infinity, alignment: .center)
        .focusSectionCompat()
    }
}
#endif

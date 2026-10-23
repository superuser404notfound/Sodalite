#if os(tvOS)
import SwiftUI

/// Where focus can sit inside the shell. The content's own focus stays the content's business.
enum SidebarFocus: Hashable {
    case item(ShellTab)
}

/// Sodalite#140. One rail row. Deliberately thin: every decision it could get wrong lives in
/// `SidebarItemState` and `SidebarMetrics`, which are pinned by tests.
struct SidebarItemRow: View {
    let tab: ShellTab
    let isSelected: Bool
    let isExpanded: Bool
    @FocusState.Binding var focus: SidebarFocus?
    let onSelect: () -> Void

    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.appState) private var appState

    private var isFocused: Bool { focus == .item(tab) }

    private var state: SidebarItemState {
        .resolve(isFocused: isFocused, isSelected: isSelected)
    }

    private var iconColor: Color {
        state.usesAccentIcon ? appearanceTheme.palette.control.color : state.iconFallbackColor
    }

    var body: some View {
        HStack(spacing: 0) {
            if tab == .profiles, let user = appState.activeUser {
                SidebarProfileAvatar(user: user)
                    .frame(width: SidebarMetrics.iconColumn, height: SidebarMetrics.iconColumn)
            } else {
                // .monochrome for the same reason the tab bar needs it: "tv" renders hierarchically
                // and would otherwise ignore the colour it is given.
                Image(systemName: tab.systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: SidebarMetrics.iconSize))
                    .foregroundStyle(iconColor)
                    .frame(width: SidebarMetrics.iconColumn)
            }
            SidebarRevealedLabel(isExpanded: isExpanded) {
                // Both colours stand in place and only cross-fade. Recoloured as focus arrives, the
                // label went white on the brightening pill and vanished for the length of the fade.
                ZStack(alignment: .leading) {
                    label
                        .foregroundStyle(SidebarItemState.selected.labelColor)
                        .opacity(state == .focused ? 0 : 1)
                    label
                        .foregroundStyle(SidebarItemState.focused.labelColor)
                        .opacity(state == .focused ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, SidebarMetrics.itemHorizontalPadding(isExpanded: isExpanded))
        .padding(.vertical, SidebarMetrics.itemVerticalPadding)
        .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
        .background(
            RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius)
                .fill(state.fill)
        )
        // Only the selected row is reachable while the rail is cold. Focus arriving from the content
        // lands geometrically, so anything else here means the viewer sees it land on the wrong row
        // and jump. Correcting it afterwards is visible as a blink; refusing it is not.
        .focusableSurface(isExpanded || isSelected)
        .focused($focus, equals: .item(tab))
        // The house helper for a Select press on a focusable row, focus-gated like every other one.
        .stableTap(isFocused: isFocused) {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var label: Text {
        if tab == .profiles, let user = appState.activeUser {
            Text(verbatim: user.name)
        } else {
            tab.title
        }
    }
}
/// A rail label that opens by width with the rail instead of appearing at its final place. Inserted
/// whole, the labels stood at full width while the glass panel was still narrow, so for the length
/// of the expand they lay over the content beside the rail (measured with a slowed animation).
///
/// The text is laid out once at the full budget and only the window onto it moves, so it never
/// re-truncates mid-animation. The gap to the icon lives inside the window, or the collapsed row
/// would keep it.
struct SidebarRevealedLabel<Label: View>: View {
    let isExpanded: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            // .headline (38pt on tvOS 26), not .title3: title3 is 48pt there, and the longest label
            // at that size ("Einstellungen") does not fit the rail.
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: SidebarMetrics.labelWidthBudget, alignment: .leading)
            .padding(.leading, SidebarMetrics.labelSpacing)
            .frame(width: isExpanded ? SidebarMetrics.labelWidthBudget + SidebarMetrics.labelSpacing : 0,
                   alignment: .leading)
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .accessibilityHidden(!isExpanded)
    }
}
#endif

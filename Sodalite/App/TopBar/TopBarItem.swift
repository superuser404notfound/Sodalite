#if os(tvOS)
import SwiftUI

/// Where focus can sit inside the top bar. The content's own focus stays the content's business.
enum TopBarFocus: Hashable {
    case item(AppTab)
}

/// One tab in the top bar: its icon always, its title only while it is the selected tab. The title
/// opens and closes by width, the way the player's transport pills reveal theirs, so the bar breathes
/// instead of jumping. Each item carries its own pill and fades it, the way the transport pills do.
struct TopBarItem: View {
    let tab: AppTab
    let isSelected: Bool
    /// The bar holds focus, so the active item is the white focus pill rather than the resting one.
    let barIsFocused: Bool
    @FocusState.Binding var focus: TopBarFocus?
    let onClick: () -> Void

    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.appState) private var appState

    /// Measured width of the full title, so the visible copy can animate from zero to it.
    @State private var labelWidth: CGFloat = 0

    private var isFocused: Bool { focus == .item(tab) }

    private var state: SidebarItemState {
        .resolve(isFocused: isFocused, isSelected: isSelected)
    }

    private var foreground: Color {
        state.usesAccentIcon ? appearanceTheme.palette.navigation.color : state.iconFallbackColor
    }

    var body: some View {
        HStack(spacing: 0) {
            icon
            title
                .frame(width: isSelected ? (labelWidth > 0 ? labelWidth : nil) : 0, alignment: .leading)
                .opacity(isSelected ? 1 : 0)
                .clipped()
        }
        .padding(.horizontal, TopBarMetrics.itemHorizontalPadding)
        .frame(height: TopBarMetrics.itemHeight)
        .fixedSize(horizontal: true, vertical: false)
        // A hidden full-size copy measures the title even while the visible one is closed.
        .background(alignment: .leading) {
            title
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
        }
        // Always present and only recoloured: one pill handed between items by matched geometry
        // jumped to the new item a frame early and dragged the title's position with it (measured).
        .background(Capsule().fill(state.fill))
        .contentShape(Capsule())
        // Only the selected tab takes focus while the bar is cold, so an up-press from the content
        // lands on it rather than on whichever icon happens to sit above (the sidebar's rule).
        .focusableSurface(barIsFocused || isSelected)
        .focused($focus, equals: .item(tab))
        .stableTap(isFocused: isFocused) {
            onClick()
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        if tab == .profiles, let user = appState.activeUser {
            SidebarProfileAvatar(user: user)
                .frame(width: TopBarMetrics.avatarDiameter, height: TopBarMetrics.avatarDiameter)
        } else {
            // .monochrome: "tv" renders hierarchically and would otherwise ignore the colour.
            Image(systemName: tab.systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.callout.weight(.semibold))
                .foregroundStyle(foreground)
        }
    }

    /// Both colours stand in place and only cross-fade. Recolouring one copy as focus arrived rebuilt
    /// the text, and a rebuilt text lands at its END position at once while the item is still moving
    /// there, so the title slid in from under the icon (measured with a slowed animation).
    private var title: some View {
        ZStack(alignment: .leading) {
            titleText
                .foregroundStyle(SidebarItemState.selected.labelColor)
                .opacity(state == .focused ? 0 : 1)
            titleText
                .foregroundStyle(SidebarItemState.focused.labelColor)
                .opacity(state == .focused ? 1 : 0)
        }
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .padding(.leading, TopBarMetrics.labelSpacing)
        .fixedSize()
    }

    private var titleText: Text {
        if tab == .profiles, let user = appState.activeUser {
            Text(verbatim: user.name)
        } else {
            Text(tab.labelKey)
        }
    }

    private var accessibilityTitle: Text {
        titleText
    }
}
#endif

#if os(tvOS)
import SwiftUI

/// Sodalite#140. Who is signed in, at the top of the rail.
///
/// Not `ActiveUserBadge`: that one is corner chrome (a floating capsule with material, shadow and a
/// trailing anchor) and, by its own rule, only appears when the server has more than one remembered
/// profile. In a sidebar the question "who am I" is worth answering on every server, and the answer
/// has to look like the rows under it rather than like a badge that wandered in.
struct SidebarProfileHeader: View {
    let isExpanded: Bool

    @Environment(\.appState) private var appState

    private var user: JellyfinUser? { appState.activeUser }

    var body: some View {
        if let user {
            HStack(spacing: 0) {
                SidebarProfileAvatar(user: user)
                    .frame(width: SidebarMetrics.iconColumn, height: SidebarMetrics.iconColumn)
                SidebarRevealedLabel(isExpanded: isExpanded) {
                    Text(user.name)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, SidebarMetrics.itemHorizontalPadding(isExpanded: isExpanded))
            .padding(.vertical, SidebarMetrics.itemVerticalPadding)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            // Display only, like the badge it replaces: focus belongs to the rows below, and an
            // up-press from the first row should reach the content, not stop here.
            .allowsHitTesting(false)
        }
    }
}

/// The header's avatar, shared with the profile row that takes its place when there is more than
/// one profile to switch between.
///
/// On the focused row's white pill it goes black like the glyphs beside it: white initials in a
/// white-on-white circle and a white hairline left nothing to see there (Sodalite#207).
struct SidebarProfileAvatar: View {
    let user: JellyfinUser
    var state: SidebarItemState = .rest

    @Environment(\.dependencies) private var dependencies

    private var isOnFocusPill: Bool { state == .focused }

    var body: some View {
        ZStack {
            if let url = dependencies.jellyfinImageService.userProfileImageURL(
                userID: user.id,
                tag: user.primaryImageTag
            ) {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsCircle(for: user)
                }
                .clipShape(Circle())
            } else {
                initialsCircle(for: user)
            }
        }
        .overlay(
            Circle().strokeBorder(
                isOnFocusPill ? state.labelColor : Color.Theme.hairline,
                lineWidth: isOnFocusPill ? 2 : 1
            )
        )
    }

    private func initialsCircle(for user: JellyfinUser) -> some View {
        ZStack {
            Circle().fill(isOnFocusPill ? Color.clear : Color.Theme.restFill)
            Text(Self.initials(for: user.name))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(state.labelColor)
        }
    }

    static func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
#endif

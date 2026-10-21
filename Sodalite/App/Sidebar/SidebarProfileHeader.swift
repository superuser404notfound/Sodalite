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
            HStack(spacing: SidebarMetrics.labelSpacing) {
                SidebarProfileAvatar(user: user)
                    .frame(width: SidebarMetrics.iconColumn, height: SidebarMetrics.iconColumn)
                if isExpanded {
                    Text(user.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
struct SidebarProfileAvatar: View {
    let user: JellyfinUser

    @Environment(\.dependencies) private var dependencies

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
        .overlay(Circle().strokeBorder(Color.Theme.hairline, lineWidth: 1))
    }

    private func initialsCircle(for user: JellyfinUser) -> some View {
        ZStack {
            Circle().fill(Color.Theme.restFill)
            Text(Self.initials(for: user.name))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
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

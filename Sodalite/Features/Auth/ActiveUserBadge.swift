import SwiftUI

/// Display-only badge: non-focusable (`allowsHitTesting(false)`, no `.focusable`) so an up-press lands on the Home tab (issue #25). Only renders when the active server has >1 remembered profile.
///
/// The count is handed in, not read here (Sodalite#169). This view is empty until it knows the count,
/// and behind the shell's `if` an empty view is never started: its `.task` never ran, so the count
/// stayed 0 and the badge never showed (measured on device and reproduced on the tvOS 27 simulator).
struct ActiveUserBadge: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    let rememberedCount: Int
    /// iOS: the badge opens the profile picker. nil keeps it display-only, which tvOS needs so an
    /// up-press lands on the Home tab (issue #25).
    var onTap: (() -> Void)? = nil

    private let diameter: CGFloat = 36

    var body: some View {
        Group {
            if let user = appState.activeUser, rememberedCount > 1 {
                content(for: user)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rememberedCount)
        .animation(.easeInOut(duration: 0.2), value: appState.activeUser?.id)
    }

    // MARK: - Content

    private func content(for user: JellyfinUser) -> some View {
        HStack(spacing: 8) {
            Text(user.name)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(1)
            avatar(for: user)
        }
        // Tight insets so the avatar nearly defines the pill height (compact account chip).
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // .ultraThinMaterial matches the detail-view frosted bubbles: more presence than plain white, lighter than .regularMaterial (read too dark).
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(
            Capsule().strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        // Width-cap + right-anchor: long names truncate instead of growing left into the tab-bar pills.
        .frame(maxWidth: 360, alignment: .trailing)
        // Title-safe top; negative offset lifts center level with the tab-bar pills (sit above the title-safe inset).
        .padding(.trailing, 6)
        .offset(y: -4)
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
        .allowsHitTesting(onTap != nil)
        .accessibilityAddTraits(onTap != nil ? .isButton : [])
    }

    private func avatar(for user: JellyfinUser) -> some View {
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
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            } else {
                initialsCircle(for: user)
                    .frame(width: diameter, height: diameter)
            }
        }
        .overlay(
            Circle().strokeBorder(Color.Theme.hairline, lineWidth: 1)
        )
    }

    private func initialsCircle(for user: JellyfinUser) -> some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Text(initials(for: user.name))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

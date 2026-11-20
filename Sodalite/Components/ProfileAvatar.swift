import SwiftUI

extension String {
    /// Two letters for a name: first letters of the first two words, else the first two letters.
    var profileInitials: String {
        let parts = split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(prefix(2)).uppercased()
    }
}

extension DependencyContainer {
    /// Avatar of a profile on a named server. Never with a token: Jellyfin serves a user's primary
    /// image without one, and an avatar is drawn for profiles whose server is not (or not yet) the
    /// verified live session, so a token here could only go to a host nothing proved (ASD-R201).
    func profileAvatarURL(userID: String, tag: String?, baseURL: URL) -> URL? {
        jellyfinImageService.userProfileImageURL(userID: userID, tag: tag, baseURL: baseURL, token: nil)
    }

    /// Avatar of the signed-in profile, through the image service's endpoint for the active session.
    func activeProfileAvatarURL(userID: String, tag: String?) -> URL? {
        jellyfinImageService.userProfileImageURL(userID: userID, tag: tag)
    }
}

/// The round profile picture with the initials fallback, drawn the same everywhere. Where the URL
/// comes from is decided by the caller through `DependencyContainer.profileAvatarURL`.
struct ProfileAvatar: View {
    let name: String
    let url: URL?
    var diameter: CGFloat?
    var font: Font = .system(size: 44, weight: .semibold, design: .rounded)
    var fill: AnyShapeStyle = AnyShapeStyle(.ultraThinMaterial)
    var textStyle: AnyShapeStyle = AnyShapeStyle(.primary)

    var body: some View {
        ZStack {
            if let url {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsCircle
                }
                .sized(diameter)
                .clipShape(Circle())
            } else {
                initialsCircle.sized(diameter)
            }
        }
    }

    private var initialsCircle: some View {
        ZStack {
            Circle().fill(fill)
            Text(name.profileInitials)
                .font(font)
                .foregroundStyle(textStyle)
        }
    }
}

private extension View {
    @ViewBuilder
    func sized(_ diameter: CGFloat?) -> some View {
        if let diameter { frame(width: diameter, height: diameter) } else { self }
    }
}

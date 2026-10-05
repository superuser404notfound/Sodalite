import Foundation

enum ImageType: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
}

final class JellyfinImageService {
    /// Base URL and token of the server an image lives on; nil `serverID` means the active one
    /// (Sodalite#85).
    private let endpoint: (String?) -> (baseURL: URL, token: String?)?

    init(endpoint: @escaping (String?) -> (baseURL: URL, token: String?)?) {
        self.endpoint = endpoint
    }

    convenience init(
        baseURLProvider: @escaping () -> URL?,
        accessTokenProvider: @escaping () -> String? = { nil }
    ) {
        self.init(endpoint: { _ in baseURLProvider().map { ($0, accessTokenProvider()) } })
    }

    func imageURL(
        itemID: String,
        serverID: String? = nil,
        imageType: ImageType = .primary,
        tag: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil
    ) -> URL? {
        guard let (base, token) = endpoint(serverID) else { return nil }
        return Self.buildURL(
            base: base,
            path: "/Items/\(itemID)/Images/\(imageType.rawValue)",
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            token: token
        )
    }

    /// Manual concat (not "\(base)") so a trailing-slash baseURL doesn't double-slash (some proxies reject it); threads the token through both `api_key` (classic) and `ApiKey` (10.9+) for version coverage.
    private static func buildURL(
        base: URL,
        path: String,
        tag: String?,
        maxWidth: Int?,
        maxHeight: Int?,
        token: String?
    ) -> URL? {
        var baseString = base.absoluteString
        while baseString.hasSuffix("/") { baseString.removeLast() }
        let leadingPath = path.hasPrefix("/") ? path : "/\(path)"

        var queryItems: [String] = []
        if let tag { queryItems.append("tag=\(tag)") }
        if let maxWidth { queryItems.append("maxWidth=\(maxWidth)") }
        if let maxHeight { queryItems.append("maxHeight=\(maxHeight)") }
        queryItems.append("quality=90")
        if let token {
            queryItems.append("api_key=\(token)")
            queryItems.append("ApiKey=\(token)")
        }

        var raw = baseString + leadingPath
        if !queryItems.isEmpty {
            raw += "?" + queryItems.joined(separator: "&")
        }
        return URL(string: raw)
    }

    func backdropURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.fullBleed) -> URL? {
        if let tags = item.backdropImageTags, let tag = tags.first {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return imageURL(itemID: seriesId, serverID: item.serverID, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// Sodalite#50. Skips the item's own backdrop and goes straight to the parent series, so a
    /// veiled episode cannot paint its own art full bleed behind the whole screen.
    func parentBackdropURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.fullBleed) -> URL? {
        guard let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId
        else { return nil }
        return imageURL(itemID: seriesId, serverID: item.serverID, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
    }

    /// Sodalite#66. Show-level art only: the series backdrop, else the series poster. Never the
    /// item's own still or backdrop, so a veiled episode can be painted unblurred wherever the
    /// user asked for show art (Continue Watching set to Backdrop or Thumb).
    func seriesArtworkURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.wideCard) -> URL? {
        if let url = parentBackdropURL(for: item, maxWidth: maxWidth) { return url }
        guard let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag else { return nil }
        return imageURL(itemID: seriesId, serverID: item.serverID, imageType: .primary, tag: tag, maxWidth: maxWidth)
    }

    /// Episode thumbnail fallback chain: own primary → own thumb → own backdrop → series backdrop → series poster.
    func episodeThumbnailURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.wideCard) -> URL? {
        if let tag = item.imageTags?.primary {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.imageTags?.thumb {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .thumb, tag: tag, maxWidth: maxWidth)
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return imageURL(itemID: seriesId, serverID: item.serverID, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        if item.type == .episode, let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemID: seriesId, serverID: item.serverID, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// 16:9 card art in a folder-browsed library (Sodalite#180). A video's own primary is already its
    /// still; a folder's primary is usually a portrait or a square channel avatar, so its thumb and
    /// backdrop go first and the primary is the last resort.
    func folderBrowseArtworkURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.wideCard) -> URL? {
        guard item.type == .folder else { return episodeThumbnailURL(for: item, maxWidth: maxWidth) }
        if let tag = item.imageTags?.thumb {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .thumb, tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .backdrop, tag: tag, maxWidth: maxWidth)
        }
        return posterURL(for: item, maxWidth: maxWidth)
    }

    func posterURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.card) -> URL? {
        if let tag = item.imageTags?.primary {
            return imageURL(itemID: item.id, serverID: item.serverID, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        if item.type == .episode, let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemID: seriesId, serverID: item.serverID, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// Music cover: album primary image else the item's own poster.
    func musicCoverURL(for item: JellyfinItem, maxWidth: Int = ImageWidth.card) -> URL? {
        if let albumID = item.albumId, let albumTag = item.albumPrimaryImageTag {
            return imageURL(itemID: albumID, serverID: item.serverID, imageType: .primary, tag: albumTag, maxWidth: maxWidth)
        }
        return posterURL(for: item, maxWidth: maxWidth)
    }

    /// Sodalite#84. Tile art for a library (CollectionFolder / UserView): its own Primary image,
    /// else its Thumb. Nil when the library carries neither, which is what leaves the generic-icon
    /// tile on screen.
    func libraryArtworkURL(for library: JellyfinLibrary, maxWidth: Int = ImageWidth.wideCard) -> URL? {
        if let tag = library.imageTags?.primary {
            return imageURL(itemID: library.id, serverID: library.serverID, imageType: .primary, tag: tag, maxWidth: maxWidth)
        }
        if let tag = library.imageTags?.thumb {
            return imageURL(itemID: library.id, serverID: library.serverID, imageType: .thumb, tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    func personImageURL(personID: String, tag: String?, maxWidth: Int = ImageWidth.avatar, serverID: String? = nil) -> URL? {
        guard let (base, token) = endpoint(serverID), let tag else { return nil }
        return Self.buildURL(
            base: base,
            path: "/Items/\(personID)/Images/Primary",
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: nil,
            token: token
        )
    }

    /// User avatar under `/Users/{id}/Images/Primary` (vs items' `/Items` prefix). Nil when no avatar so the UI falls back to initials.
    func userProfileImageURL(userID: String, tag: String?, maxWidth: Int = ImageWidth.avatar, serverID: String? = nil) -> URL? {
        guard let (base, token) = endpoint(serverID) else { return nil }
        return userProfileImageURL(
            userID: userID, tag: tag, baseURL: base, token: token, maxWidth: maxWidth
        )
    }

    /// Avatar on a named server rather than the active one. The server list and the launch picker draw the remembered profiles of EVERY known server, and the providers above answer for whichever one happens to be active, so those URLs pointed at the wrong host with an id it does not know and answered 404 into the initials placeholder (Sodalite#119). The token belongs to the profile on that server: `AsyncCachedImage` attaches `X-Emby-Token` only for the active host, so a foreign host is served by the `api_key` in the query or not at all.
    func userProfileImageURL(
        userID: String,
        tag: String?,
        baseURL: URL,
        token: String?,
        maxWidth: Int = ImageWidth.avatar
    ) -> URL? {
        guard let tag else { return nil }
        return Self.buildURL(
            base: baseURL,
            path: "/Users/\(userID)/Images/Primary",
            tag: tag,
            maxWidth: maxWidth,
            maxHeight: nil,
            token: token
        )
    }

}

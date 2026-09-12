import Foundation

/// Subset of Jellyfin's item DTO the TopShelf renders; PascalCase keys so the same JSON the main app receives decodes here unmassaged. Codable (not just Decodable) so TopShelfCache can persist items for the offline fallback.
nonisolated struct TopShelfItem: Codable, Sendable {
    let id: String
    let name: String
    let type: TopShelfItemType
    let seriesName: String?
    let seriesId: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let imageTags: TopShelfImageTags?
    let backdropImageTags: [String]?
    let parentBackdropImageTags: [String]?
    let parentThumbImageTag: String?
    let parentThumbItemId: String?
    let runTimeTicks: Int64?
    let userData: TopShelfUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentThumbItemId = "ParentThumbItemId"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
    }
}

nonisolated enum TopShelfItemType: String, Codable, Sendable {
    case movie = "Movie"
    case series = "Series"
    case episode = "Episode"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TopShelfItemType(rawValue: raw) ?? .unknown
    }
}

nonisolated struct TopShelfImageTags: Codable, Sendable {
    let primary: String?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case thumb = "Thumb"
    }
}

/// Per-user playback state; feeds the cell's resume bar.
nonisolated struct TopShelfUserData: Codable, Sendable {
    let playedPercentage: Double?
    let playbackPositionTicks: Int64?

    enum CodingKeys: String, CodingKey {
        case playedPercentage = "PlayedPercentage"
        case playbackPositionTicks = "PlaybackPositionTicks"
    }
}

nonisolated extension TopShelfItem {
    /// Wide thumbnail for the carousel cell, along whichever chain the viewer picked in Settings
    /// (`TopShelfArtwork`). Episode resolution is capped at the server's image-extraction-width
    /// setting (320 old default, can't upscale client-side), which is the reason the choice exists:
    /// a still that reads fine on a card can be soft on a cell three times its width.
    func topShelfImageURL(baseURL: URL, token: String, artwork: TopShelfArtwork.Choice) -> URL? {
        guard let source = TopShelfArtwork.source(for: artwork, available) else { return nil }
        return imageURL(baseURL: baseURL,
                        itemID: source.itemID,
                        kind: source.kind.rawValue,
                        tag: source.tag,
                        token: token)
    }

    private var available: TopShelfArtwork.Available {
        TopShelfArtwork.Available(isEpisode: type == .episode,
                                  itemID: id,
                                  seriesID: seriesId,
                                  primary: imageTags?.primary,
                                  thumb: imageTags?.thumb,
                                  backdrop: backdropImageTags?.first,
                                  parentBackdrop: parentBackdropImageTags?.first,
                                  parentThumb: parentThumbImageTag,
                                  parentThumbID: parentThumbItemId)
    }

    /// The cell as the artwork renderer wants it. Both callers go through this: the extension when
    /// it has to render on the spot, and the app when it renders ahead of time. Two mappings would
    /// be two chances to pick a different picture, and the file names would then miss each other.
    nonisolated func artworkCell(session: SharedSession,
                                 artwork: TopShelfArtwork.Choice) -> ResumeBarArtwork.Cell? {
        guard let remote = topShelfImageURL(baseURL: session.baseURL,
                                            token: session.accessToken,
                                            artwork: artwork)
        else { return nil }
        return ResumeBarArtwork.Cell(itemID: id, remote: remote, fraction: topShelfProgress)
    }

    /// Resume bar for the cell. Percentage first (what /Items/Resume returns), ticks as the
    /// fallback for anything that only carries a position.
    var topShelfProgress: Double? {
        TopShelfProgress.fraction(playedPercentage: userData?.playedPercentage,
                                  positionTicks: userData?.playbackPositionTicks,
                                  runTimeTicks: runTimeTicks)
    }

    /// Card headline: movies render bare name; episodes prefix series + S/E breadcrumb (the still alone doesn't identify the show).
    var topShelfTitle: String {
        guard type == .episode, let series = seriesName else { return name }
        return EpisodeMetadataFormatter.label(seriesName: series,
                                              season: parentIndexNumber,
                                              episode: indexNumber,
                                              title: name)
    }

    /// format=Jpg so the image-cache daemon never hits a WebP/AVIF response ImageIO can choke on in
    /// the tight extension budget, and it costs nothing on a JPEG source, which Jellyfin passes
    /// through unconverted. The width is `ImageWidth.topShelfSource`, a cap rather than a request,
    /// and no `quality`: both exist to stop the server re-encoding a file it could hand over as it
    /// is. enableImageEnhancers=false skips a downscaling server transform.
    private func imageURL(baseURL: URL, itemID: String, kind: String, tag: String, token: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let raw = "\(base)/Items/\(itemID)/Images/\(kind)?tag=\(tag)&maxWidth=\(ImageWidth.topShelfSource)&format=Jpg&enableImageEnhancers=false&api_key=\(token)"
        return URL(string: raw)
    }
}

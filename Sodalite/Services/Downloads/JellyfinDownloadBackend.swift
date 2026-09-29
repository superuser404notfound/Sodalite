import AVFoundation
import Foundation

/// `DownloadBackend` over the live session (Sodalite#81). Reads everything through the container at
/// call time, so a profile or token change is picked up by the next request.
@MainActor
final class JellyfinDownloadBackend: DownloadBackend {
    private weak var container: DependencyContainer?
    private let fetchSession = URLSession(configuration: .default, delegate: ServerTrustDelegate.shared, delegateQueue: nil)

    init(container: DependencyContainer) {
        self.container = container
    }

    var baseURL: URL? { container?.jellyfinClient.baseURL }
    var authorization: String { container?.jellyfinClient.buildAuthHeader() ?? "" }
    var userID: String { container?.activeUserID ?? "" }
    var preferredAudioLanguage: String? { container?.playbackPreferences.preferredAudioLanguage }
    var allowsCellular: Bool { !(container?.downloadPreferences.wifiOnly ?? true) }

    struct Unavailable: LocalizedError {
        var errorDescription: String? {
            String(localized: "downloads.error.server", defaultValue: "The server could not provide this download.")
        }
    }

    struct BadStatus: LocalizedError {
        let status: Int
        var errorDescription: String? {
            String(localized: "downloads.error.server", defaultValue: "The server could not provide this download.")
        }
    }

    func playbackInfo(itemID: String, profile: [String: Any], mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse {
        guard let container else { throw Unavailable() }
        return try await container.jellyfinPlaybackService.getPlaybackInfo(
            itemID: itemID, userID: userID, profile: profile, mediaSourceID: mediaSourceID, audioStreamIndex: audioStreamIndex)
    }

    func itemDetail(itemID: String) async throws -> JellyfinItem {
        guard let container else { throw Unavailable() }
        return try await container.jellyfinItemService.getItemDetail(userID: userID, itemID: itemID)
    }

    func seasonEpisodes(seriesID: String, seasonID: String) async throws -> [JellyfinItem] {
        guard let container else { throw Unavailable() }
        return try await container.jellyfinPlaybackService.getEpisodes(seriesID: seriesID, seasonID: seasonID, userID: userID)
    }

    func subtitleURL(itemID: String, mediaSourceID: String, stream: MediaStream) -> URL? {
        container?.jellyfinPlaybackService.buildSubtitleURL(itemID: itemID, mediaSourceID: mediaSourceID,
                                                            streamIndex: stream.index, format: stream.codec ?? "srt")
    }

    func artworkURLs(for item: JellyfinItem) -> [DownloadArtwork: URL] {
        guard let images = container?.jellyfinImageService else { return [:] }
        var urls: [DownloadArtwork: URL] = [:]
        urls[.poster] = images.posterURL(for: item)
        urls[.backdrop] = images.backdropURL(for: item)
        if item.seriesId != nil {
            urls[.thumb] = images.episodeThumbnailURL(for: item)
            if let seriesID = item.seriesId {
                urls[.seriesPoster] = images.imageURL(itemID: seriesID, imageType: .primary, tag: item.seriesPrimaryImageTag, maxWidth: 600)
            }
        }
        return urls
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await fetchSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw BadStatus(status: status) }
        return data
    }

    func availableCapacity() -> Int64? {
        #if os(iOS)
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    func stopEncoding(playSessionID: String) async {
        try? await container?.jellyfinPlaybackService.stopActiveEncodings(playSessionID: playSessionID)
    }

    /// A transcode download is a fragmented mp4, which AVFoundation reads the length of.
    func mediaDuration(of url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }
}

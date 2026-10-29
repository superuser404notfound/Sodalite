import AVFoundation
import Foundation

/// `DownloadBackend` over the live session (Sodalite#81). Reads everything through the container at
/// call time, so a profile or token change is picked up by the next request. With a `serverID` it
/// talks to that server of a combined Home instead, through its own session (Sodalite#202).
@MainActor
final class JellyfinDownloadBackend: DownloadBackend {
    private weak var container: DependencyContainer?
    private let serverID: String?
    private static let fetchSession = URLSession(configuration: .default, delegate: ServerTrustDelegate.shared, delegateQueue: nil)

    init(container: DependencyContainer, serverID: String? = nil) {
        self.container = container
        self.serverID = serverID
    }

    private var secondary: ServerSession? {
        serverID.flatMap { container?.sessionRegistry.secondary(serverID: $0) }
    }

    private var client: JellyfinClient? { serverID == nil ? container?.jellyfinClient : secondary?.client }
    private var playbackService: JellyfinPlaybackServiceProtocol? {
        serverID == nil ? container?.jellyfinPlaybackService : secondary?.playbackService
    }
    private var itemService: JellyfinItemServiceProtocol? {
        serverID == nil ? container?.jellyfinItemService : secondary?.itemService
    }

    var baseURL: URL? { client?.baseURL }
    var authorization: String { client?.buildAuthHeader() ?? "" }
    var userID: String { (serverID == nil ? container?.activeUserID : secondary?.userID) ?? "" }
    var preferredAudioLanguage: String? { container?.playbackPreferences.preferredAudioLanguage }
    var versionOrder: VersionOrder { container?.playbackPreferences.versionOrder ?? .quality }
    var allowsCellular: Bool { !(container?.downloadPreferences.wifiOnly ?? true) }
    /// By the policy of the account the download is fetched as, as for streaming.
    var canTranscodeVideo: Bool {
        guard serverID != nil else { return container?.appState?.activeUser?.canTranscodeVideo ?? true }
        return secondary?.user?.canTranscodeVideo ?? true
    }

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
        guard let playbackService else { throw Unavailable() }
        return try await playbackService.getPlaybackInfo(
            itemID: itemID, userID: userID, profile: profile, mediaSourceID: mediaSourceID, audioStreamIndex: audioStreamIndex)
    }

    func itemDetail(itemID: String) async throws -> JellyfinItem {
        guard let itemService else { throw Unavailable() }
        return try await itemService.getItemDetail(userID: userID, itemID: itemID)
    }

    func seasonEpisodes(seriesID: String, seasonID: String) async throws -> [JellyfinItem] {
        guard let playbackService else { throw Unavailable() }
        return try await playbackService.getEpisodes(seriesID: seriesID, seasonID: seasonID, userID: userID)
    }

    func subtitleURL(itemID: String, mediaSourceID: String, stream: MediaStream) -> URL? {
        playbackService?.buildSubtitleURL(itemID: itemID, mediaSourceID: mediaSourceID,
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
                urls[.seriesPoster] = images.imageURL(itemID: seriesID, serverID: item.serverID, imageType: .primary,
                                                      tag: item.seriesPrimaryImageTag, maxWidth: 600)
            }
        }
        return urls
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.fetchSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw BadStatus(status: status) }
        return data
    }

    func availableCapacity() -> Int64? {
        #if !os(tvOS)
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    func stopEncoding(playSessionID: String) async {
        try? await playbackService?.stopActiveEncodings(playSessionID: playSessionID)
    }

    /// A transcode download is a fragmented mp4, which AVFoundation reads the length of.
    func mediaDuration(of url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }
}

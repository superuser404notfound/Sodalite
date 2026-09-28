import Foundation

/// Where one download stands (Sodalite#81). `missingOnServer` is a complete download whose item the
/// server no longer has: the file stays and keeps playing, the tab says so.
enum DownloadState: String, Codable, Sendable {
    case queued, downloading, paused, failed, complete, missingOnServer
}

/// Original = the file itself through `Items/{id}/Download`; transcode = Jellyfin's progressive fMP4.
enum DownloadRoute: String, Codable, Sendable {
    case original, transcode
}

enum DownloadFailure: String, Codable, Sendable {
    /// 403 or 400 on `Items/{id}/Download`: the user policy forbids downloading, or the item cannot be.
    case notAllowed
    /// 401: the token the task was created with no longer works.
    case unauthorized
    case noSpace
    case network
    case server
}

/// The position a local session last reached, and when it was last reconciled with the server.
struct DownloadLocalProgress: Codable, Sendable, Equatable {
    var positionTicks: Int64 = 0
    var played: Bool = false
    var lastPlayed: Date?
    var lastSyncedAt: Date?
}

struct DownloadManifest: Codable, Sendable, Equatable {
    let itemID: String
    let seriesID: String?
    let seasonID: String?
    let quality: StreamingQuality
    let route: DownloadRoute
    let mediaSourceID: String
    let audioStreamIndex: Int?
    /// The PlaySessionId a transcode was started under, so a cancel can kill its encode.
    var playSessionID: String?
    /// A transcode's token-free URL, kept so a restart after a relaunch needs no new PlaybackInfo.
    var transcodeURL: String?
    var mediaFileName: String?
    /// Stream index to sidecar file name inside the item directory.
    var subtitleFiles: [Int: String] = [:]
    var expectedBytes: Int64?
    /// The item's runtime, so a transcode that ended early can be told from a whole one.
    var runtimeTicks: Int64?
    var receivedBytes: Int64 = 0
    private(set) var state: DownloadState
    var failure: DownloadFailure?
    var progress = DownloadLocalProgress()
    let createdAt: Date

    init(itemID: String, seriesID: String?, seasonID: String?, quality: StreamingQuality,
         route: DownloadRoute, mediaSourceID: String, audioStreamIndex: Int?, playSessionID: String?,
         state: DownloadState, createdAt: Date) {
        self.itemID = itemID
        self.seriesID = seriesID
        self.seasonID = seasonID
        self.quality = quality
        self.route = route
        self.mediaSourceID = mediaSourceID
        self.audioStreamIndex = audioStreamIndex
        self.playSessionID = playSessionID
        self.state = state
        self.createdAt = createdAt
    }

    /// Moves the state along an allowed edge and reports whether it did. A complete download never
    /// goes back into the queue: re-downloading is delete plus a new download.
    /// A finished file is finished, whatever the queue thought meanwhile: a pause or a requeue that
    /// raced the last bytes must not throw the file away.
    mutating func complete() {
        if state == .paused || state == .failed { transition(to: .queued) }
        if state == .queued { transition(to: .downloading) }
        transition(to: .complete)
        failure = nil
    }

    @discardableResult
    mutating func transition(to next: DownloadState) -> Bool {
        let allowed: Set<DownloadState> = switch state {
        case .queued: [.downloading, .paused, .failed]
        case .downloading: [.paused, .failed, .complete, .queued]
        case .paused: [.queued]
        case .failed: [.queued]
        case .complete: [.missingOnServer]
        case .missingOnServer: [.complete]
        }
        guard allowed.contains(next) else { return false }
        state = next
        if next == .queued { failure = nil }
        return true
    }
}

/// What the player and the offline pages need to know about an item without a server.
struct DownloadSnapshot: Codable, Sendable {
    let item: JellyfinItem
    let series: JellyfinItem?
    let season: JellyfinItem?
    /// The source as the LOCAL file carries it: for a transcode, only the streams that survived it.
    let source: PlaybackMediaSource
}

enum DownloadArtwork: String, CaseIterable, Sendable {
    case poster, backdrop, thumb, seriesPoster

    var fileName: String {
        switch self {
        case .poster: "poster.jpg"
        case .backdrop: "backdrop.jpg"
        case .thumb: "thumb.jpg"
        case .seriesPoster: "series-poster.jpg"
        }
    }
}

struct DownloadedItem: Identifiable, Sendable {
    var manifest: DownloadManifest
    let snapshot: DownloadSnapshot
    let directory: URL

    var id: String { manifest.itemID }

    var mediaURL: URL? {
        manifest.mediaFileName.map { directory.appendingPathComponent($0) }
    }

    func subtitleURL(forStream index: Int) -> URL? {
        manifest.subtitleFiles[index].map { directory.appendingPathComponent($0) }
    }

    func artworkURL(_ kind: DownloadArtwork) -> URL? {
        let url = directory.appendingPathComponent(kind.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

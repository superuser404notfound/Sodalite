import Foundation
import Observation

enum DownloadEnqueueError: LocalizedError, Equatable {
    case noSpace
    case noServer
    case noSource

    var errorDescription: String? {
        switch self {
        case .noSpace:
            String(localized: "downloads.error.noSpace", defaultValue: "Not enough free space for this download.")
        case .noServer, .noSource:
            String(localized: "downloads.error.server", defaultValue: "The server could not provide this download.")
        }
    }
}

enum DownloadEvent: Sendable {
    case progress(DownloadTaskTag, written: Int64, expected: Int64)
    case finished(DownloadTaskTag, status: Int, movedTo: URL?)
    case failed(DownloadTaskTag, resumeData: Data?, cancelled: Bool)
}

/// Foreground API the manager needs; production is `JellyfinDownloadBackend`.
@MainActor
protocol DownloadBackend: AnyObject {
    var baseURL: URL? { get }
    var authorization: String { get }
    var userID: String { get }
    var preferredAudioLanguage: String? { get }
    var allowsCellular: Bool { get }
    func playbackInfo(itemID: String, profile: [String: Any], mediaSourceID: String?, audioStreamIndex: Int?) async throws -> PlaybackInfoResponse
    func itemDetail(itemID: String) async throws -> JellyfinItem
    func seasonEpisodes(seriesID: String, seasonID: String) async throws -> [JellyfinItem]
    func subtitleURL(itemID: String, mediaSourceID: String, stream: MediaStream) -> URL?
    func artworkURLs(for item: JellyfinItem) -> [DownloadArtwork: URL]
    func fetch(_ request: URLRequest) async throws -> Data
    func availableCapacity() -> Int64?
    func stopEncoding(playSessionID: String) async
}

/// The background session; production is `DownloadSessionDelegate`'s session.
@MainActor
protocol DownloadTransport: AnyObject {
    @discardableResult
    func start(request: URLRequest, resumeData: Data?, tag: DownloadTaskTag, allowsCellular: Bool) -> Int
    func cancel(tag: DownloadTaskTag, producingResumeData: Bool) async -> Data?
    func liveTags() async -> Set<DownloadTaskTag>
}

/// Queue and lifecycle of the downloads (Sodalite#81). The store is the truth; this class only moves
/// manifests between states and keeps the background session busy within the scheduler's limits.
@MainActor @Observable
final class DownloadManager {
    private let store: DownloadStore
    @ObservationIgnored private let backend: any DownloadBackend
    @ObservationIgnored private let transport: any DownloadTransport
    /// itemID to a 0...1 fraction while a task runs; not persisted.
    private(set) var liveProgress: [String: Double] = [:]
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var resumeData: [String: Data] = [:]

    init(store: DownloadStore, backend: any DownloadBackend, transport: any DownloadTransport) {
        self.store = store
        self.backend = backend
        self.transport = transport
    }

    // MARK: Enqueue

    func enqueue(item: JellyfinItem, quality: StreamingQuality) async throws {
        guard store.item(item.id) == nil else { return }
        guard let profile = store.activeProfile, let baseURL = backend.baseURL else { throw DownloadEnqueueError.noServer }

        let probe = try await backend.playbackInfo(itemID: item.id, profile: DirectPlayProfile.downloadProfile(maxStreamingBitrate: quality.maxStreamingBitrate), mediaSourceID: nil, audioStreamIndex: nil)
        guard let first = probe.mediaSources.first else { throw DownloadEnqueueError.noSource }
        let audio = DownloadPlanner.audioStreamIndex(preferredLanguage: backend.preferredAudioLanguage, streams: first.mediaStreams ?? [])
        // Ask again pinned to the audio track when a transcode is going to happen: Jellyfin only
        // applies AudioStreamIndex when the request names the source (MediaInfoHelper), and the
        // pinned body already carries MediaSourceId and SubtitleStreamIndex -1 (no burn-in).
        let info = quality.bites(sourceBitrate: first.bitrate)
            ? try await backend.playbackInfo(itemID: item.id, profile: DirectPlayProfile.downloadProfile(maxStreamingBitrate: quality.maxStreamingBitrate), mediaSourceID: first.id, audioStreamIndex: audio)
            : probe
        guard let source = info.mediaSources.first else { throw DownloadEnqueueError.noSource }

        let detail = (try? await backend.itemDetail(itemID: item.id)) ?? item
        let plan = DownloadPlanner.plan(itemID: item.id, source: source, quality: quality, runtimeTicks: detail.runTimeTicks,
                                        audioStreamIndex: audio, baseURL: baseURL)
        if DownloadPlanner.refusesForSpace(estimate: plan.expectedBytes, available: backend.availableCapacity()) {
            throw DownloadEnqueueError.noSpace
        }

        var series: JellyfinItem?
        var season: JellyfinItem?
        if let seriesID = detail.seriesId { series = try? await backend.itemDetail(itemID: seriesID) }
        if let seasonID = detail.seasonId { season = try? await backend.itemDetail(itemID: seasonID) }

        var manifest = DownloadManifest(itemID: item.id, seriesID: detail.seriesId, seasonID: detail.seasonId, quality: quality,
                                        route: plan.route, mediaSourceID: source.id,
                                        audioStreamIndex: plan.route == .transcode ? audio : nil,
                                        playSessionID: info.playSessionId, state: .queued, createdAt: Date())
        manifest.expectedBytes = plan.expectedBytes
        manifest.transcodeURL = plan.route == .transcode ? plan.url.absoluteString : nil
        manifest.progress.positionTicks = detail.userData?.playbackPositionTicks ?? 0
        manifest.progress.played = detail.userData?.played ?? false
        manifest.progress.lastPlayed = JellyfinDate.parse(detail.userData?.lastPlayedDate)
        let created = try store.create(manifest, snapshot: DownloadSnapshot(item: detail, series: series, season: season, source: plan.localSource))

        await fetchSidecars(plan: plan, item: created, profile: profile)
        await fetchArtwork(for: detail, series: series, into: created.directory)
        pumpQueue()
    }

    func enqueueSeason(seriesID: String, seasonID: String, quality: StreamingQuality) async throws {
        for episode in try await backend.seasonEpisodes(seriesID: seriesID, seasonID: seasonID) {
            try await enqueue(item: episode, quality: quality)
        }
    }

    // MARK: Control

    func pause(itemID: String) async {
        guard let item = store.item(itemID), item.manifest.state == .downloading || item.manifest.state == .queued,
              let tag = tag(for: item) else { return }
        let data = await transport.cancel(tag: tag, producingResumeData: item.manifest.route == .original)
        if let data { resumeData[itemID] = data; try? data.write(to: resumeURL(item)) }
        try? store.update(itemID: itemID) { $0.transition(to: .paused) }
        liveProgress[itemID] = nil
        pumpQueue()
    }

    func resume(itemID: String) {
        try? store.update(itemID: itemID) { $0.transition(to: .queued) }
        pumpQueue()
    }

    func retry(itemID: String) {
        guard store.item(itemID)?.manifest.state == .failed else { return }
        resume(itemID: itemID)
    }

    func cancel(itemID: String) async {
        guard let item = store.item(itemID) else { return }
        if let tag = tag(for: item) { _ = await transport.cancel(tag: tag, producingResumeData: false) }
        if item.manifest.route == .transcode, item.manifest.state != .complete, let session = item.manifest.playSessionID {
            await backend.stopEncoding(playSessionID: session)
        }
        resumeData[itemID] = nil
        liveProgress[itemID] = nil
        try? store.delete(itemID: itemID)
        pumpQueue()
    }

    /// Relaunch: a manifest still `downloading` without a live task is an orphan and goes back to the
    /// queue; one with a live task keeps it, so the same file is never fetched twice.
    func reattach() async {
        let live = await transport.liveTags()
        for item in store.items.values where item.manifest.state == .downloading {
            guard let tag = tag(for: item), !live.contains(tag) else { continue }
            try? store.update(itemID: item.id) { $0.transition(to: .queued) }
        }
        pumpQueue()
    }

    // MARK: Events

    func handle(event: DownloadEvent) async {
        switch event {
        case let .progress(tag, written, expected):
            guard let item = store.item(tag.itemID) else { return }
            let total = expected > 0 ? expected : (item.manifest.expectedBytes ?? 0)
            liveProgress[tag.itemID] = total > 0 ? min(Double(written) / Double(total), 0.99) : nil
        case let .finished(tag, status, movedTo):
            liveProgress[tag.itemID] = nil
            if let failure = DownloadPlanner.failure(forStatus: status) {
                if let movedTo { try? FileManager.default.removeItem(at: movedTo) }
                try? store.update(itemID: tag.itemID) { $0.failure = failure; $0.transition(to: .failed) }
            } else if let movedTo {
                let size = (try? movedTo.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                try? store.update(itemID: tag.itemID) {
                    $0.mediaFileName = movedTo.lastPathComponent
                    $0.receivedBytes = size ?? 0
                    $0.transition(to: .complete)
                }
                if let item = store.item(tag.itemID) { try? FileManager.default.removeItem(at: resumeURL(item)) }
            }
            pumpQueue()
        case let .failed(tag, data, cancelled):
            liveProgress[tag.itemID] = nil
            guard !cancelled, let item = store.item(tag.itemID) else { return }
            if item.manifest.route == .original, let data {
                resumeData[tag.itemID] = data
                try? data.write(to: resumeURL(item))
            }
            try? store.update(itemID: tag.itemID) { $0.failure = .network; $0.transition(to: .failed) }
            pumpQueue()
        }
    }

    // MARK: Private

    private func pumpQueue() {
        let all = Array(store.items.values.map(\.manifest))
        let ids = DownloadScheduler.toStart(queued: all.filter { $0.state == .queued },
                                            running: all.filter { $0.state == .downloading })
        for id in ids { start(itemID: id) }
    }

    private func start(itemID: String) {
        guard let item = store.item(itemID), let baseURL = backend.baseURL, let tag = tag(for: item) else { return }
        let url: URL
        switch item.manifest.route {
        case .original:
            url = baseURL.appendingPathComponent("Items").appendingPathComponent(itemID).appendingPathComponent("Download")
        case .transcode:
            // Rebuilt from the stored PlaySession: a running encode serves no ranges, so an
            // interrupted transcode always starts over. PlaybackInfo is asked again lazily only if
            // this URL answers 4xx (see handle(.finished)).
            guard let relative = item.manifest.transcodeURL, let built = URL(string: relative, relativeTo: baseURL)?.absoluteURL else { return }
            url = built
        }
        let data = item.manifest.route == .original ? (resumeData[itemID] ?? (try? Data(contentsOf: resumeURL(item)))) : nil
        resumeData[itemID] = nil
        try? store.update(itemID: itemID) { $0.transition(to: .downloading) }
        transport.start(request: DownloadPlanner.authorizedRequest(url: url, authorization: backend.authorization),
                        resumeData: data, tag: tag, allowsCellular: backend.allowsCellular)
    }

    private func tag(for item: DownloadedItem) -> DownloadTaskTag? {
        guard let profile = store.activeProfile else { return nil }
        let ext = item.manifest.route == .transcode ? "mp4" : (item.snapshot.source.container.flatMap { $0.split(separator: ",").first.map(String.init) } ?? "mkv")
        return DownloadTaskTag(serverID: profile.serverID, userID: profile.userID, itemID: item.id,
                               fileExtension: ext == "matroska" ? "mkv" : ext)
    }

    private func resumeURL(_ item: DownloadedItem) -> URL {
        item.directory.appendingPathComponent("resume.data")
    }

    private func fetchSidecars(plan: DownloadPlanner.Plan, item: DownloadedItem, profile: ProfileKey) async {
        var files: [Int: String] = [:]
        for stream in plan.sidecarStreams {
            guard let url = backend.subtitleURL(itemID: item.id, mediaSourceID: item.manifest.mediaSourceID, stream: stream),
                  let data = try? await backend.fetch(DownloadPlanner.authorizedRequest(url: url, authorization: backend.authorization)) else { continue }
            let name = "sub-\(stream.index).\(url.pathExtension.isEmpty ? "srt" : url.pathExtension)"
            guard (try? data.write(to: item.directory.appendingPathComponent(name), options: .atomic)) != nil else { continue }
            files[stream.index] = name
        }
        try? store.update(itemID: item.id) { $0.subtitleFiles = files }
    }

    private func fetchArtwork(for item: JellyfinItem, series: JellyfinItem?, into directory: URL) async {
        for (kind, url) in backend.artworkURLs(for: item) {
            guard let data = try? await backend.fetch(DownloadPlanner.authorizedRequest(url: url, authorization: backend.authorization)) else { continue }
            try? data.write(to: directory.appendingPathComponent(kind.fileName), options: .atomic)
        }
    }
}

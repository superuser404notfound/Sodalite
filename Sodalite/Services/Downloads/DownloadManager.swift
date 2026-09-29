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
    /// iOS cancelled the task itself (the app was force-quit, background refresh turned off, the
    /// system short on resources): an interruption, not the viewer's cancel.
    case interrupted(DownloadTaskTag, resumeData: Data?)
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
    /// Seconds of media in a finished file, nil when it cannot be read.
    func mediaDuration(of url: URL) async -> Double?
}

/// The background session; production is `DownloadSessionDelegate`'s session.
@MainActor
protocol DownloadTransport: AnyObject {
    @discardableResult
    func start(request: URLRequest, resumeData: Data?, tag: DownloadTaskTag, allowsCellular: Bool) -> Int
    func cancel(tag: DownloadTaskTag, producingResumeData: Bool) async -> Data?
    func liveTags() async -> Set<DownloadTaskTag>
    func cancelAll(where matches: @escaping @Sendable (DownloadTaskTag) -> Bool) async
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
        // What is queued or running has not landed yet, but it will: its bytes are spoken for.
        let reserved = store.items.values
            .filter { [.queued, .downloading, .paused].contains($0.manifest.state) }
            .reduce(Int64(0)) { $0 + max(($1.manifest.expectedBytes ?? 0) - $1.manifest.receivedBytes, 0) }
        if DownloadPlanner.refusesForSpace(estimate: plan.expectedBytes,
                                           available: backend.availableCapacity().map { $0 - reserved }) {
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
        manifest.runtimeTicks = detail.runTimeTicks
        // Checked again after the awaits above: a second tap, or a season overlapping a single
        // episode, must not create the item twice and start a second task on the same file.
        guard store.item(item.id) == nil, store.activeProfile == profile else { return }
        let created = try store.create(manifest, snapshot: DownloadSnapshot(item: detail, series: series, season: season, source: plan.localSource))

        await fetchSidecars(plan: plan, item: created, profile: profile)
        await fetchArtwork(for: detail, series: series, into: created.directory)
        pumpQueue()
    }

    /// One episode the server refuses does not cost the rest of the season; running out of space does,
    /// since every episode after it would be refused the same way. The first error is still reported.
    func enqueueSeason(seriesID: String, seasonID: String, quality: StreamingQuality) async throws {
        var firstError: Error?
        for episode in try await backend.seasonEpisodes(seriesID: seriesID, seasonID: seasonID) {
            do {
                try await enqueue(item: episode, quality: quality)
            } catch DownloadEnqueueError.noSpace {
                throw DownloadEnqueueError.noSpace
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: Control

    func pause(itemID: String) async {
        guard let item = store.item(itemID), item.manifest.state == .downloading || item.manifest.state == .queued,
              let tag = tag(for: item) else { return }
        let data = await transport.cancel(tag: tag, producingResumeData: item.manifest.route == .original)
        if let data { try? data.write(to: resumeURL(tag)) }
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
        liveProgress[itemID] = nil
        try? store.delete(itemID: itemID)
        pumpQueue()
    }

    /// Stops every task a server, or one profile on it, still runs: a purge of a profile that is not
    /// the active one has nothing in `items` to walk, and its tasks would keep downloading.
    func cancelTasks(serverID: String?, userID: String?) async {
        await transport.cancelAll { tag in
            (serverID == nil || tag.serverID == serverID) && (userID == nil || tag.userID == userID)
        }
    }

    /// Relaunch: a manifest still `downloading` without a live task finished while the app was gone
    /// (its file is there) or is an orphan (back to the queue); one with a live task keeps it, so the
    /// same file is never fetched twice.
    func reattach() async {
        let live = await transport.liveTags()
        for item in store.items.values where item.manifest.state == .downloading {
            guard let tag = tag(for: item), !live.contains(tag) else { continue }
            if let file = store.mediaFile(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) {
                await finish(tag, file: file)
            } else {
                try? store.update(itemID: item.id) { $0.transition(to: .queued) }
            }
        }
        pumpQueue()
    }

    /// The Wi-Fi only switch changed: a running task keeps the network access it was created with,
    /// so it is restarted under the new one (an original from where it was).
    func applyNetworkPolicy() async {
        for item in store.items.values where item.manifest.state == .downloading {
            guard let tag = tag(for: item) else { continue }
            let data = await transport.cancel(tag: tag, producingResumeData: item.manifest.route == .original)
            if let data { try? data.write(to: resumeURL(tag)) }
            start(itemID: item.id)
        }
    }

    // MARK: Events

    /// Resolves every event through the tag's own directory, never through `items`: iOS delivers a
    /// finished download after relaunching the app in the background, where no scene exists and no
    /// profile is active, and a tag can belong to a profile that is not the active one.
    func handle(event: DownloadEvent) async {
        switch event {
        case let .progress(tag, written, expected):
            guard isActive(tag), let item = store.item(tag.itemID) else { return }
            let total = expected > 0 ? expected : (item.manifest.expectedBytes ?? 0)
            liveProgress[tag.itemID] = total > 0 ? min(Double(written) / Double(total), 0.99) : nil
        case let .finished(tag, status, movedTo):
            liveProgress[tag.itemID] = nil
            if let failure = DownloadPlanner.failure(forStatus: status) {
                if let movedTo { try? FileManager.default.removeItem(at: movedTo) }
                // Resume data carries the old request, header included: after any HTTP answer it is
                // worth nothing and would replay a dead token forever.
                try? FileManager.default.removeItem(at: resumeURL(tag))
                try? store.updateManifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) {
                    $0.failure = failure
                    $0.transition(to: .failed)
                }
            } else if let movedTo {
                await finish(tag, file: movedTo)
            }
            pumpQueue()
        case let .interrupted(tag, data):
            liveProgress[tag.itemID] = nil
            guard let manifest = store.manifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) else { return }
            if manifest.route == .original, let data { try? data.write(to: resumeURL(tag)) }
            // Back into the queue, so it continues on its own (from the resume data where there is
            // one) instead of waiting for a retry the viewer never asked to need.
            try? store.updateManifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) {
                $0.transition(to: .queued)
            }
            pumpQueue()
        case let .failed(tag, data, cancelled):
            liveProgress[tag.itemID] = nil
            guard !cancelled,
                  let manifest = store.manifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) else { return }
            if manifest.route == .original, let data { try? data.write(to: resumeURL(tag)) }
            try? store.updateManifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) {
                $0.failure = .network
                $0.transition(to: .failed)
            }
            pumpQueue()
        }
    }

    /// A file arrived. A transcode has no length to check against, so a stream that ended early
    /// (ffmpeg died) would look whole; its duration is compared with the runtime instead.
    private func finish(_ tag: DownloadTaskTag, file: URL) async {
        guard let manifest = store.manifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) else { return }
        if manifest.route == .transcode, let runtime = manifest.runtimeTicks,
           let duration = await backend.mediaDuration(of: file),
           Self.isTruncated(duration: duration, runtimeTicks: runtime) {
            try? FileManager.default.removeItem(at: file)
            try? store.updateManifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) {
                $0.failure = .server
                $0.transition(to: .failed)
            }
            return
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        try? FileManager.default.removeItem(at: resumeURL(tag))
        try? store.updateManifest(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID) {
            $0.mediaFileName = file.lastPathComponent
            $0.receivedBytes = size ?? 0
            $0.complete()
        }
    }

    /// More than a minute or five percent short of the runtime, whichever is larger.
    static func isTruncated(duration: Double, runtimeTicks: Int64) -> Bool {
        let runtime = Double(runtimeTicks) / 10_000_000
        guard runtime > 0 else { return false }
        return duration < runtime - max(60, runtime * 0.05)
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
        // Consumed once: a resumed task keeps the request it was created with, so resume data
        // must never be replayed after it has been tried.
        let data = item.manifest.route == .original ? (try? Data(contentsOf: resumeURL(tag))) : nil
        try? FileManager.default.removeItem(at: resumeURL(tag))
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

    private func resumeURL(_ tag: DownloadTaskTag) -> URL {
        store.paths.itemDirectory(serverID: tag.serverID, userID: tag.userID, itemID: tag.itemID)
            .appendingPathComponent("resume.data")
    }

    private func isActive(_ tag: DownloadTaskTag) -> Bool {
        store.activeProfile?.serverID == tag.serverID && store.activeProfile?.userID == tag.userID
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

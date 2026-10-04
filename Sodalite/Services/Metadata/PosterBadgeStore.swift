import Foundation
import Observation

/// Fetches the half of the badge data that is not free (Sodalite#79).
///
/// Resolution rides along on every card query, but dynamic range and spatial audio only exist in
/// `MediaStreams`, and Jellyfin's DtoService answers that field with a `GetStaticMediaSources` call
/// per item, which is exactly the cost Sodalite#68 took out of the grids. So the streams are never
/// part of the card field set: they are fetched afterwards, batched by id, cached per item, and the
/// result lives here rather than in `FilterCache`, whose keys must keep carrying one single field
/// set no matter who writes them.
@Observable
@MainActor
final class PosterBadgeStore {

    /// Movies and episodes answer for themselves; a series has no streams of its own, so it is
    /// sampled from its newest episode. Everything else (collections, folders, playlists, music)
    /// is never asked about.
    private static let batchSize = 40

    /// The library service and user an item's server answers through. A nil user means the
    /// caller's, which is how the active server keeps reading `AppState.activeUser` (Sodalite#85).
    private let route: @MainActor (_ serverID: String?) -> (library: JellyfinLibraryServiceProtocol, userID: String?)
    private let isEnabled: @MainActor () -> Bool

    /// `JellyfinItem.originKey` -> what its streams said. An entry with empty badges is a negative result and stops
    /// the id from being asked about again.
    private var enriched: [String: MediaBadges] = [:]
    private var inFlight: Set<String> = []
    /// Tail of the series-sampling chain. Home shows several rows at once, each with its own task,
    /// so per-row serialisation would still let ten rows fan out; the chain makes it one sample at
    /// a time for the whole app.
    private var seriesTail: Task<Void, Never>?

    /// `userID` is passed per call rather than resolved here: `DependencyContainer.activeUserID`
    /// reads the keychain, and the callers hold `AppState.activeUser?.id` already (same reason
    /// `spoilerPolicy(userID:)` takes it as a parameter, Sodalite#50).
    init(route: @escaping @MainActor (String?) -> (library: JellyfinLibraryServiceProtocol, userID: String?),
         isEnabled: @escaping @MainActor () -> Bool) {
        self.route = route
        self.isEnabled = isEnabled
    }

    /// What the card should paint right now: the free resolution immediately, anything the
    /// enrichment has since found layered on top.
    func badges(for item: JellyfinItem) -> MediaBadges {
        let base = MediaBadgeResolver.badges(width: item.width, height: item.height, streams: item.mediaStreams)
        guard let found = enriched[item.originKey] else { return base }
        return MediaBadges(resolution: found.resolution ?? base.resolution,
                           dynamicRange: found.dynamicRange ?? base.dynamicRange,
                           audio: found.audio ?? base.audio,
                           audioCodec: found.audioCodec ?? base.audioCodec,
                           channelLayout: found.channelLayout ?? base.channelLayout)
    }

    func enrich(userID: String, _ items: [JellyfinItem]) async {
        guard isEnabled() else { return }

        var direct: [JellyfinItem] = []
        var series: [JellyfinItem] = []
        // An item that already carries its streams (anything fetched with detailFields) answers
        // itself; asking the server again would buy nothing.
        for item in items where enriched[item.originKey] == nil && !inFlight.contains(item.originKey)
                                && item.mediaStreams == nil {
            switch item.type {
            case .movie, .episode: direct.append(item)
            case .series:          series.append(item)
            default:               continue
            }
        }
        guard !direct.isEmpty || !series.isEmpty else { return }

        let keys = Set((direct + series).map(\.originKey))
        inFlight.formUnion(keys)
        defer { inFlight.subtract(keys) }

        // One batch run per server: an id means nothing to a server that did not mint it.
        for (serverID, group) in Dictionary(grouping: direct, by: \.serverID) {
            let target = route(serverID)
            let ids = group.map(\.id)
            for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
                await fetchBatch(Array(ids[start..<min(start + Self.batchSize, ids.count)]),
                                 serverID: serverID, library: target.library, userID: target.userID ?? userID)
            }
        }
        // Series go one at a time on purpose: a sample cannot be batched with another series', and
        // this chain is what keeps a screenful of rows from firing off ten badge samples at once
        // (the limiter's background lane, Sodalite#72/AsyncSemaphore.swift:9-19, only orders what's
        // already queued). Re-checked every iteration: `.task(id:)` cancelling mid-chain (scroll
        // away, profile switch, the setting turned off) must stop enqueueing new samples, not just
        // skip writing the ones already in flight (Audit 2026-09-25 NETWORK-5).
        for item in series {
            guard !Task.isCancelled, isEnabled() else { return }
            let target = route(item.serverID)
            await enqueueSample(item.id, serverID: item.serverID, library: target.library, userID: target.userID ?? userID)
        }
    }

    private func fetchBatch(_ ids: [String], serverID: String?, library: JellyfinLibraryServiceProtocol, userID: String) async {
        let response: JellyfinItemsResponse
        do {
            response = try await library.getItems(
                userID: userID,
                query: ItemQuery(ids: ids, fields: "MediaStreams"))
        } catch {
            return  // Nothing cached, so a later pass over the same row tries again.
        }
        // Seed every requested id, not just the answered ones: an item the server says nothing
        // about must not be asked a second time on every scroll.
        let key = { (id: String) in "\(serverID ?? "")|\(id)" }
        var found = Dictionary(uniqueKeysWithValues: ids.map { (key($0), MediaBadges()) })
        for item in response.items {
            found[key(item.id)] = MediaBadgeResolver.badges(width: item.width, height: item.height, streams: item.mediaStreams)
        }
        enriched.merge(found) { _, new in new }
    }

    private func enqueueSample(_ seriesID: String, serverID: String?, library: JellyfinLibraryServiceProtocol, userID: String) async {
        let previous = seriesTail
        let sample = Task { @MainActor [weak self] in
            await previous?.value
            await self?.sampleSeries(seriesID, serverID: serverID, library: library, userID: userID)
        }
        seriesTail = sample
        // `sample` is unstructured and does not inherit this call's cancellation on its own
        // (Audit 2026-09-25 NETWORK-5): without the handler, a `.task(id:)` cancelling here left
        // this one sample (and, transitively via `previous`, the whole remaining chain) running to
        // completion against the shared limiter.
        await withTaskCancellationHandler {
            await sample.value
        } onCancel: {
            sample.cancel()
        }
    }

    private func sampleSeries(_ seriesID: String, serverID: String?, library: JellyfinLibraryServiceProtocol, userID: String) async {
        let query = ItemQuery(parentID: seriesID,
                              includeItemTypes: [.episode],
                              sortBy: "DateCreated",
                              sortOrder: "Descending",
                              limit: 1,
                              fields: "MediaStreams")
        guard let response = try? await library.getItems(userID: userID, query: query) else { return }
        enriched["\(serverID ?? "")|\(seriesID)"] = response.items.first.map {
            MediaBadgeResolver.badges(width: $0.width, height: $0.height, streams: $0.mediaStreams)
        } ?? MediaBadges()
    }
}

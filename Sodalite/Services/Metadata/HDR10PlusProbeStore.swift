import Foundation
import Observation
import AetherEngine

/// The one badge fact a Jellyfin scan cannot deliver (AE#579).
///
/// HDR10+ rides an in-band ITU-T T.35 SEI inside the video packets. Only Matroska hands a demuxer
/// packet side data for it, so a library scan that stops at the container reports plain `HDR10` for
/// an HEVC file in MP4 or TS that carries the dynamic metadata. The engine answers the question
/// without playing anything (`AetherEngine.probe(url:detecting: .hdr10Plus)`), which costs one open
/// and a handful of packets, so it is asked at exactly one place: a detail page that is already
/// showing an HDR10 pill, once per version per session.
///
/// Held in memory on purpose. A persistent answer would need an invalidation story for the day the
/// file behind an id is replaced, and the probe is cheap enough that a cold start can pay it again.
@Observable
@MainActor
final class HDR10PlusProbeStore {

    /// What the engine pass is allowed to spend. `maxPacketBytes` is the one that needs saying: a
    /// UHD HEVC keyframe runs to several MB, and the 2 MiB default would reject it before inspection
    /// on exactly the content this feature targets. The whole-probe budget sits above the pass's own
    /// 16 MiB so the pass stops at its cap rather than the probe throwing.
    nonisolated static let limits = ProbeLimits(
        maxInputBytes: 24 * 1024 * 1024,
        maxPackets: 256,
        maxPacketBytes: 16 * 1024 * 1024,
        timeBudget: 10
    )

    private struct Key: Hashable {
        let serverID: String?
        let itemID: String
        let sourceID: String
    }

    /// Versions whose file was opened and found to carry ST 2094-40.
    private var confirmed: Set<Key> = []
    /// Versions that have been answered, either way. A failure counts: a page that is reopened
    /// should not reopen the file each time a server is slow.
    private var answered: Set<Key> = []
    private var inFlight: Set<Key> = []

    /// Takes the item so the URL is built against the server it came from (Sodalite#85).
    private let streamURL: @MainActor (_ item: JellyfinItem, _ sourceID: String, _ container: String?) -> URL?
    private let isEnabled: @MainActor () -> Bool
    private let probe: @Sendable (URL, ProbeCancellation) throws -> Bool

    init(streamURL: @escaping @MainActor (JellyfinItem, String, String?) -> URL?,
         isEnabled: @escaping @MainActor () -> Bool,
         probe: @escaping @Sendable (URL, ProbeCancellation) throws -> Bool = HDR10PlusProbeStore.engineProbe) {
        self.streamURL = streamURL
        self.isEnabled = isEnabled
        self.probe = probe
    }

    /// The default pass. Blocking FFmpeg work, so every caller runs it off the main actor.
    nonisolated static let engineProbe: @Sendable (URL, ProbeCancellation) throws -> Bool = { url, cancellation in
        try AetherEngine.probe(url: url, detecting: .hdr10Plus,
                               limits: limits, cancellation: cancellation).carriesHDR10PlusMetadata
    }

    /// Whether this version was opened and found to carry HDR10+. False while nothing is known,
    /// which is also what a page wants to paint: the server's own answer, unchanged.
    ///
    /// Takes the item, not an id, so the key is built the same way on both sides. A page passes the
    /// version it is showing, and `VersionSelection.preferredSourceID` is nil for the ordinary
    /// single-source title: reading the raw id here would have missed every answer the probe wrote
    /// under the resolved source.
    func carriesHDR10Plus(item: JellyfinItem, sourceID: String?) -> Bool {
        guard let source = item.effectiveMediaSource(id: sourceID) else { return false }
        return confirmed.contains(Key(serverID: item.serverID, itemID: item.id, sourceID: source.id))
    }

    /// The only case worth a connection: a movie or episode whose badge currently reads plain HDR10.
    ///
    /// Dolby Vision is left alone (its badge already outranks this one and a DV file can carry an
    /// HDR10+ layer without the page having anything better to say), a server that already resolved
    /// HDR10+ is not asked again, and SDR / HLG have no HDR10 base layer to upgrade.
    static func shouldProbe(item: JellyfinItem, sourceID: String?) -> Bool {
        guard item.type == .movie || item.type == .episode else { return false }
        guard item.effectiveMediaSource(id: sourceID) != nil else { return false }
        let badges = MediaBadgeResolver.badges(
            width: item.width,
            height: item.height,
            streams: item.effectiveMediaStreams(id: sourceID))
        return badges.dynamicRange == .hdr10
    }

    /// Ask once, for the version the page is showing. Silent on every failure path: this only ever
    /// upgrades a badge, so a source that cannot be opened simply keeps the server's answer.
    func probeIfNeeded(item: JellyfinItem, sourceID: String?) async {
        guard isEnabled(), Self.shouldProbe(item: item, sourceID: sourceID) else { return }
        guard let source = item.effectiveMediaSource(id: sourceID) else { return }

        let key = Key(serverID: item.serverID, itemID: item.id, sourceID: source.id)
        guard !answered.contains(key), !inFlight.contains(key) else { return }
        guard let url = streamURL(item, source.id, source.container) else { return }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let probe = self.probe
        // A viewer who leaves the page takes the connection with them: the task the page owns is
        // cancelled, and that has to reach a blocking read inside FFmpeg, which only the engine's
        // own cancellation token can do.
        let cancellation = ProbeCancellation()
        let carries = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { () -> Bool? in
                do {
                    return try probe(url, cancellation)
                } catch {
                    return nil
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }

        guard !Task.isCancelled else { return }
        answered.insert(key)
        if carries == true {
            confirmed.insert(key)
            LogTap.shared.note("[Badges] HDR10+ confirmed by probe for \(item.id)")
        }
    }
}

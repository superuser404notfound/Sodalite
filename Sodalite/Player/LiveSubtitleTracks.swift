import Foundation
import AetherEngine

/// Live TV has no Jellyfin media-stream list: the live load returns before the VOD mapping, so
/// `subtitleStreams` stays empty and everything reading it (both pickers, the automatic pick, the
/// skip-back window) finds nothing. The engine demuxes the transport stream regardless and publishes
/// what it found, so that list is mapped into the shape the host already speaks.
///
/// `index` carries `TrackInfo.id`, the AVStream index, which is what
/// `AetherEngine.selectSubtitleTrack(index:)` expects back. Nothing is invented: a name the broadcast
/// does not carry stays nil instead of being synthesised into a display string.
enum LiveSubtitleTracks {
    static func mediaStreams(from tracks: [TrackInfo]) -> [MediaStream] {
        tracks
            // External tracks carry a synthetic id (AE#88), not an AVStream index, and reach the
            // engine through the external select path. They cannot occur on live, and mapping one
            // would publish an index that resolves to nothing.
            .filter { !$0.isExternal }
            .map { EngineSubtitleInventory.mediaStream(from: $0, index: $0.id, displayTitle: nil) }
    }
}

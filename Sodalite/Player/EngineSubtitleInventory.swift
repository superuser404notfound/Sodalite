import Foundation
import AetherEngine

/// Sodalite#247: the subtitle tracks the engine found in the file that Jellyfin's stream list does
/// not name. A server whose probe was slow, failed or never ran hands PlaybackInfo an incomplete
/// list, and the menu used to show only that list even though the engine had opened every track.
///
/// Jellyfin's list stays the base: its entries keep their index, name and flags, so a server with
/// complete metadata sees no change at all. The engine only adds what is missing. An entry Jellyfin
/// names but the engine does not have is kept, because a selection that finds nothing is no worse
/// than the menu was before, and the engine's list cannot tell "not in the file" from "not
/// published yet" on every route.
///
/// An added track gets a menu index of its own, `menuIndexBase` plus its engine id, so it can never
/// collide with a Jellyfin index and keeps its place when Jellyfin renumbers after a subtitle download.
enum EngineSubtitleInventory {
    static let menuIndexBase = 1_000_000

    static func menuIndex(forEngineTrackID id: Int) -> Int { menuIndexBase + id }

    /// The engine id behind an index this type handed out; nil for a Jellyfin index.
    static func engineTrackID(forMenuIndex index: Int) -> Int? {
        index >= menuIndexBase ? index - menuIndexBase : nil
    }

    /// Engine tracks read out of the played file: container streams and the A53 captions the
    /// engine finds in the video (99608). Sidecars (100000+) are Jellyfin's own externals coming
    /// back, the remote HLS and live rendition ranges (200000+) are not container streams.
    static func isContainerTrack(_ track: TrackInfo) -> Bool {
        !track.isExternal && track.id >= 0 && track.id < AetherEngine.externalSubtitleTrackIDBase
    }

    /// The menu list: Jellyfin's subtitle streams, then the container tracks it does not name, through
    /// the one dedupe the menu always used. Jellyfin's entries come first, so with nothing missing the
    /// result is exactly `PlayerViewModel.dedupedSubtitleStreams(from:)`.
    static func mergedStreams(sourceStreams: [MediaStream], engineTracks: [TrackInfo]) -> [MediaStream] {
        let named = Set(sourceStreams
            .filter { $0.type == .subtitle && $0.isExternal != true }
            .map { PlayerViewModel.embeddedEngineTrackID(forJellyfinIndex: $0.index, in: sourceStreams) })
        let added = engineTracks
            .filter { isContainerTrack($0) && !named.contains($0.id) }
            .map { mediaStream(from: $0, index: menuIndex(forEngineTrackID: $0.id), displayTitle: $0.name) }
        return PlayerViewModel.dedupedSubtitleStreams(from: sourceStreams + added)
    }

    /// An engine track in the shape the menu speaks. `displayTitle` is what the menu falls back to
    /// when the track has no language: the engine's own name ("Closed Captions", "Track 3 (subrip)")
    /// says more than "Unknown".
    static func mediaStream(from track: TrackInfo, index: Int, displayTitle: String?) -> MediaStream {
        var stream = MediaStream(index: index, type: .subtitle, codec: track.codec,
                                 language: track.language, displayTitle: displayTitle,
                                 title: track.name.isEmpty ? nil : track.name,
                                 isDefault: track.isDefault, isForced: track.isForced,
                                 isExternal: false, height: nil, width: nil, channels: nil,
                                 videoRange: nil, videoRangeType: nil, averageFrameRate: nil,
                                 realFrameRate: nil, profile: nil, bitRate: nil, dvProfile: nil)
        stream.isHearingImpaired = track.isHearingImpaired
        return stream
    }
}

import Foundation

/// An audio or subtitle choice made on a detail page before playback (Sodalite#250).
///
/// It travels in the shape the player already consumes for a remembered pick, a `TrackMemoryEntry`,
/// and stands in for that entry on the launch item's first load only. The stream indices are
/// Jellyfin's for the source named by `sourceID`; they settle the case a signature cannot, two
/// tracks that look the same, and are used only where they still describe the file being played.
struct LaunchTrackPick: Equatable, Sendable {
    struct Audio: Equatable, Sendable {
        var streamIndex: Int
        var signature: TrackSignature
    }

    enum Subtitle: Equatable, Sendable {
        case off
        case track(streamIndex: Int, signature: TrackSignature)
    }

    var itemID: String
    var sourceID: String?
    /// nil leaves the axis to the automatic path.
    var audio: Audio?
    var subtitle: Subtitle?

    var isEmpty: Bool { audio == nil && subtitle == nil }

    /// The remembered entry with every picked axis replaced by the pick.
    func overriding(_ remembered: TrackMemoryEntry?, now: Date = Date()) -> TrackMemoryEntry {
        var entry = remembered ?? TrackMemoryEntry(subtitle: nil, audio: nil, updatedAt: now)
        if let audio { entry.audio = audio.signature }
        switch subtitle {
        case .off: entry.subtitle = .off
        case .track(_, let signature): entry.subtitle = .track(signature)
        case nil: break
        }
        return entry
    }

    /// The container index to open the picked audio with. Only under direct play of the picked
    /// source, where Jellyfin's numbering is the file's own; nil hands it to the signature path.
    func preloadAudioIndex(playedSourceID: String?, isDirectPlay: Bool, mediaStreams: [MediaStream]) -> Int? {
        guard let audio, isDirectPlay, playsPickedSource(playedSourceID) else { return nil }
        return PlayerViewModel.embeddedEngineTrackID(forJellyfinIndex: audio.streamIndex, in: mediaStreams)
    }

    /// `plan` with the picked tracks pinned by index where the indices still hold.
    ///
    /// The subtitle menu speaks Jellyfin's indices under every play method, so a subtitle index holds
    /// whenever the picked source plays. The engine's audio ids are the container's, which only direct
    /// play shares, and only an id the engine actually lists is pinned: Jellyfin can name a stream the
    /// probe skipped. "Off" needs no index and holds everywhere.
    func pinning(_ plan: TrackSelectionPlan, playedSourceID: String?, isDirectPlay: Bool,
                 mediaStreams: [MediaStream], subtitleStreams: [MediaStream],
                 engineAudioIDs: Set<Int>) -> TrackSelectionPlan {
        var pinned = plan
        let sameSource = playsPickedSource(playedSourceID)
        switch subtitle {
        case .off:
            pinned.subtitle = .off
        case .track(let index, _):
            if sameSource, subtitleStreams.contains(where: { $0.index == index }) {
                pinned.subtitle = .select(streamIndex: index)
            }
        case nil:
            break
        }
        if let audio, sameSource, isDirectPlay {
            let engineID = PlayerViewModel.embeddedEngineTrackID(forJellyfinIndex: audio.streamIndex, in: mediaStreams)
            if engineAudioIDs.contains(engineID) { pinned.audioTrackID = engineID }
        }
        return pinned
    }

    /// The audio index PlaybackInfo should name. A transcode carries only that audio, so without it
    /// the server encodes its own default and no pick after the load can reach another track. Nil
    /// when the pinned source is another version than the one picked against.
    func playbackInfoAudioIndex(pinnedSourceID: String?) -> Int? {
        guard let audio else { return nil }
        if let pinnedSourceID, pinnedSourceID != sourceID { return nil }
        return audio.streamIndex
    }

    /// What applying the plan put on screen of the PICKED subtitle, for track memory. Nil when the pick
    /// did not land: an unmatched forced pick turns into "off" in the plan, and remembering that would
    /// store the opposite of what the viewer chose.
    func appliedSubtitle(_ plan: TrackSelectionPlan, subtitleStreams: [MediaStream]) -> RememberedSubtitle? {
        switch (subtitle, plan.subtitle) {
        case (.off, .off):
            return .off
        case (.track, .select(let index)):
            return subtitleStreams.first { $0.index == index }
                .map { .track(TrackSelectionMatcher.subtitleSignature($0)) }
        default:
            return nil
        }
    }

    private func playsPickedSource(_ playedSourceID: String?) -> Bool {
        guard let playedSourceID, let sourceID else { return false }
        return playedSourceID == sourceID
    }
}

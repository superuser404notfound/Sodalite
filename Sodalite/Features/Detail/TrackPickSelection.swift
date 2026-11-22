import Foundation
import AetherEngine

/// The audio and subtitle tracks a detail page has picked for Play (Sodalite#250).
///
/// Like `VersionSelection`, the pick is stored with the item it belongs to and every read names the
/// item it asks about, so a pick never follows the page to another episode. It also names the version
/// it was made against: the viewer can switch the version after picking, and indices from one file
/// say nothing about another, so a read against a different version matches the pick again by what
/// the track is (language, codec, channels) and drops an axis that has no such track there.
struct TrackPickSelection: Equatable {
    enum SubtitleChoice: Equatable {
        case automatic
        case off
        case stream(MediaStream)
    }

    private struct Picked: Equatable {
        var sourceID: String
        var streamIndex: Int
        var signature: TrackSignature
    }

    private enum PickedSubtitle: Equatable {
        case off
        case track(Picked)
    }

    private var itemID: String?
    private var audio: Picked?
    private var subtitle: PickedSubtitle?

    // MARK: - What a source offers

    /// The audio the panel lists, the same streams the player can open.
    static func audioStreams(in source: MediaSource?) -> [MediaStream] {
        TrackSelectionMatcher.jellyfinAudioStreams(source?.mediaStreams)
    }

    /// The subtitles the panel lists, deduped the way the player's menu dedupes Jellyfin's list.
    static func subtitleStreams(in source: MediaSource?) -> [MediaStream] {
        PlayerViewModel.dedupedSubtitleStreams(from: source?.mediaStreams)
    }

    /// Something to choose: a second audio track, or any subtitle at all ("Off" is then a choice too).
    static func isOffered(for source: MediaSource?) -> Bool {
        audioStreams(in: source).count > 1 || !subtitleStreams(in: source).isEmpty
    }

    // MARK: - Picking

    /// nil goes back to automatic.
    mutating func chooseAudio(_ stream: MediaStream?, item: JellyfinItem, source: MediaSource) {
        adopt(item)
        audio = stream.map {
            Picked(sourceID: source.id, streamIndex: $0.index,
                   signature: TrackSelectionMatcher.audioSignature($0, in: source.mediaStreams ?? []))
        }
    }

    mutating func chooseSubtitle(_ choice: SubtitleChoice, item: JellyfinItem, source: MediaSource) {
        adopt(item)
        switch choice {
        case .automatic:
            subtitle = nil
        case .off:
            subtitle = .off
        case .stream(let stream):
            subtitle = .track(Picked(sourceID: source.id, streamIndex: stream.index,
                                     signature: TrackSelectionMatcher.subtitleSignature(stream)))
        }
    }

    /// A pick for another item starts from nothing; the old item's other axis must not ride along.
    private mutating func adopt(_ item: JellyfinItem) {
        guard itemID != item.id else { return }
        itemID = item.id
        audio = nil
        subtitle = nil
    }

    // MARK: - Reading

    /// The pick for `item` played from `source`, nil for another item or when nothing applies.
    func resolved(for item: JellyfinItem, source: MediaSource?) -> LaunchTrackPick? {
        guard itemID == item.id, let source else { return nil }
        let pick = LaunchTrackPick(
            itemID: item.id,
            sourceID: source.id,
            audio: audio.flatMap { resolveAudio($0, in: source) },
            subtitle: subtitle.flatMap { resolveSubtitle($0, in: source) }
        )
        return pick.isEmpty ? nil : pick
    }

    private func resolveAudio(_ picked: Picked, in source: MediaSource) -> LaunchTrackPick.Audio? {
        let streams = source.mediaStreams ?? []
        let candidates = Self.audioStreams(in: source)
        if picked.sourceID == source.id {
            guard candidates.contains(where: { $0.index == picked.streamIndex }) else { return nil }
            return LaunchTrackPick.Audio(streamIndex: picked.streamIndex, signature: picked.signature)
        }
        let tracks = candidates.map { (stream: $0, track: TrackSelectionMatcher.audioTrackInfo($0, in: streams)) }
        guard let match = TrackSelectionMatcher.matchAudio(picked.signature, in: tracks.map(\.track)),
              let stream = tracks.first(where: { $0.track.id == match.id })?.stream else { return nil }
        return LaunchTrackPick.Audio(streamIndex: stream.index, signature: picked.signature)
    }

    private func resolveSubtitle(_ picked: PickedSubtitle, in source: MediaSource) -> LaunchTrackPick.Subtitle? {
        switch picked {
        case .off:
            return .off
        case .track(let track):
            let candidates = Self.subtitleStreams(in: source)
            if track.sourceID == source.id {
                guard candidates.contains(where: { $0.index == track.streamIndex }) else { return nil }
                return .track(streamIndex: track.streamIndex, signature: track.signature)
            }
            guard let match = TrackSelectionMatcher.matchSubtitle(track.signature, in: candidates) else { return nil }
            return .track(streamIndex: match.index, signature: track.signature)
        }
    }
}

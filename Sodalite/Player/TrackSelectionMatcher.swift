import Foundation
import AetherEngine

/// A remembered track, described by what it IS rather than where it sits. Stream indices
/// shift between the episodes of a series, so a remembered pick is re-resolved against
/// each title's own track list.
struct TrackSignature: Codable, Equatable, Sendable {
    var language: String?
    var isForced: Bool
    var isExternal: Bool
    var codec: String?
    /// Normalized track role: commentary | signs | songs | sdh | forced, else nil.
    var descriptor: String?
    /// Audio only (2 = stereo, 6 = 5.1); nil for subtitles.
    var channels: Int?
}

/// "Off" is a real, rememberable choice, not the absence of one: without it the automatic
/// resolution turns subtitles back on at the next load.
enum RememberedSubtitle: Codable, Equatable, Sendable {
    case off
    case track(TrackSignature)
}

struct TrackMemoryEntry: Codable, Equatable, Sendable {
    /// nil = nothing remembered on this axis yet, so the automatic path still owns it.
    var subtitle: RememberedSubtitle?
    var audio: TrackSignature?
    /// Per entry, not per store: the cloud merge unions entries and compares these.
    var updatedAt: Date
    /// Seconds added to the global subtitle delay for this one file, nil when none is set. Only
    /// ever written under `TrackSelectionMemory.itemKey`, never under a series key.
    var subtitleOffset: Double? = nil
}

struct TrackSelectionPlan: Equatable {
    enum SubtitleAction: Equatable {
        case off
        case select(streamIndex: Int)
        /// Nothing remembered or nothing matched: today's automatic resolution decides.
        case fallThrough
    }
    var subtitle: SubtitleAction
    /// Engine track id to force after load, nil to keep the engine's own first-frame pick.
    var audioTrackID: Int?
}

/// Pure decisions for the per-title track memory (Sodalite#46), split out of PlayerViewModel
/// the way ForcedSubtitleFallback is, so the whole policy stays unit-testable.
enum TrackSelectionMatcher {

    // MARK: - Signatures

    static func subtitleSignature(_ stream: MediaStream) -> TrackSignature {
        TrackSignature(
            language: stream.language?.lowercased(),
            isForced: stream.isForced == true || (stream.title?.lowercased().contains("forced") ?? false),
            isExternal: stream.isExternal == true,
            codec: stream.codec?.lowercased(),
            descriptor: descriptor(title: stream.title, isCommentary: false),
            channels: nil
        )
    }

    static func audioSignature(_ track: TrackInfo) -> TrackSignature {
        TrackSignature(
            language: track.language?.lowercased(),
            isForced: false,
            isExternal: false,
            codec: track.codec.lowercased(),
            descriptor: descriptor(title: track.name, isCommentary: track.isCommentary),
            channels: track.channels
        )
    }

    /// Same vocabulary the subtitle deduping already uses, collapsed to one canonical token
    /// so "German (SDH)" and "Deutsch SDH" compare equal across episodes.
    static func descriptor(title: String?, isCommentary: Bool) -> String? {
        if isCommentary { return "commentary" }
        let text = (title ?? "").lowercased()
        if text.contains("commentary") { return "commentary" }
        if text.contains("signs") { return "signs" }
        if ["songs", "music", "musik"].contains(where: { text.contains($0) }) { return "songs" }
        if ["sdh", "hearing", "cc"].contains(where: { text.contains($0) }) { return "sdh" }
        if text.contains("forced") { return "forced" }
        return nil
    }

    // MARK: - Matching

    /// Language is a hard filter, and so is a remembered FORCED pick: forced lines only and every
    /// line are different choices, not a close match, so a forced memory never adopts a full track.
    static func matchSubtitle(_ signature: TrackSignature, in streams: [MediaStream]) -> MediaStream? {
        best(in: streams.filter {
                 languageMatches(signature.language, $0.language)
                     && (!signature.isForced || subtitleSignature($0).isForced)
             },
             index: { $0.index },
             score: { stream in
                 let candidate = subtitleSignature(stream)
                 var score = 0
                 if candidate.isForced == signature.isForced { score += 4 }
                 if candidate.isExternal == signature.isExternal { score += 2 }
                 if candidate.descriptor == signature.descriptor { score += 2 }
                 if candidate.codec == signature.codec { score += 1 }
                 return score
             })
    }

    static func matchAudio(_ signature: TrackSignature, in tracks: [TrackInfo]) -> TrackInfo? {
        best(in: tracks.filter { languageMatches(signature.language, $0.language) },
             index: { $0.id },
             score: { track in
                 let candidate = audioSignature(track)
                 var score = 0
                 if candidate.channels == signature.channels { score += 4 }
                 if candidate.descriptor == signature.descriptor { score += 2 }
                 if candidate.codec == signature.codec { score += 1 }
                 return score
             })
    }

    // MARK: - Plan

    static func plan(
        entry: TrackMemoryEntry?,
        subtitleStreams: [MediaStream],
        audioTracks: [TrackInfo]
    ) -> TrackSelectionPlan {
        guard let entry else { return TrackSelectionPlan(subtitle: .fallThrough, audioTrackID: nil) }

        let subtitle: TrackSelectionPlan.SubtitleAction
        switch entry.subtitle {
        case .off:
            subtitle = .off
        case .track(let signature):
            if let match = matchSubtitle(signature, in: subtitleStreams) {
                subtitle = .select(streamIndex: match.index)
            } else if signature.isForced {
                // No forced track of that language here: stay off rather than let the automatic
                // path pick the full one. The silent forced fallback still applies on its own terms.
                subtitle = .off
            } else {
                subtitle = .fallThrough
            }
        case nil:
            subtitle = .fallThrough
        }

        let audioTrackID = entry.audio.flatMap { matchAudio($0, in: audioTracks) }?.id
        return TrackSelectionPlan(subtitle: subtitle, audioTrackID: audioTrackID)
    }

    // MARK: - Helpers

    /// Unknown ("und", empty, nil) only pairs with unknown: a remembered track with no
    /// language must not adopt a tagged one, and vice versa.
    private static func languageMatches(_ remembered: String?, _ candidate: String?) -> Bool {
        let rememberedUnknown = isUnknown(remembered)
        let candidateUnknown = isUnknown(candidate)
        if rememberedUnknown || candidateUnknown { return rememberedUnknown && candidateUnknown }
        return PlayerViewModel.languagesMatch(remembered, candidate)
    }

    private static func isUnknown(_ language: String?) -> Bool {
        PlayerViewModel.isLanguageUnknown(language)
    }

    /// Highest score wins; equal scores break on the lowest index so the pick is stable.
    private static func best<T>(in candidates: [T], index: (T) -> Int, score: (T) -> Int) -> T? {
        candidates
            .map { (item: $0, score: score($0), index: index($0)) }
            .max { a, b in
                a.score != b.score ? a.score < b.score : a.index > b.index
            }?
            .item
    }
}

import Foundation

/// The media-segment kinds Sodalite offers a one-press skip for. Outro is deliberately absent:
/// it is covered by the next-episode overlay, not by a button.
enum SkipSegmentKind: Sendable {
    case recap
    case intro
    case commercial

    var buttonLabel: String {
        switch self {
        case .recap: String(localized: "player.skipRecap", defaultValue: "Skip Recap")
        case .intro: String(localized: "player.skipIntro", defaultValue: "Skip Intro")
        case .commercial: String(localized: "player.skipCommercial", defaultValue: "Skip Commercial")
        }
    }
}

/// The segment the player currently offers to skip, flattened off `MediaSegment` so the player state
/// carries only what the pill and the seek need.
struct ActiveSkipSegment: Equatable, Sendable {
    let kind: SkipSegmentKind
    let startSeconds: Double
    let endSeconds: Double
}

/// Pure rules for "which segment is skippable at this playhead". Lives outside PlayerViewModel so the
/// precedence and the visibility window are testable without an engine, same as TransportFocusOrder.
enum SkipSegmentResolver {
    /// The plugin sometimes reports a marker starting at 0 on cold opens; the floor stops the pill
    /// popping before the titles even play.
    static let visibleFloorSeconds: Double = 0.5
    /// Hide the pill shortly before the segment ends so it never outlives what it skips.
    static let hideBeforeEndSeconds: Double = 1

    /// Recap is checked first: when a recap runs straight into an intro, one press clears the recap
    /// and the next tick re-resolves to the intro, relabelling the same pill. Commercial breaks come
    /// last, each one its own segment, so back-to-back breaks chain the same way.
    static func active(
        intro: MediaSegment?,
        recap: MediaSegment?,
        commercials: [MediaSegment] = [],
        time: Double
    ) -> ActiveSkipSegment? {
        let candidates = [
            recap.map { ActiveSkipSegment(kind: .recap, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) },
            intro.map { ActiveSkipSegment(kind: .intro, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) },
        ].compactMap { $0 }
            + commercials.map { ActiveSkipSegment(kind: .commercial, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
        return candidates.first { contains($0, time: time) }
    }

    static func contains(_ segment: ActiveSkipSegment, time: Double) -> Bool {
        time >= max(segment.startSeconds, visibleFloorSeconds)
            && time < segment.endSeconds - hideBeforeEndSeconds
    }
}

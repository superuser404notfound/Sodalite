import Foundation

/// The per-title subtitle offset stepped from the player's subtitle menu. It adds to the global
/// `PlaybackPreferences.subtitleDelaySeconds`, which stays the baseline for every title.
enum SubtitleOffset {
    static let limit: Double = 10

    /// The furthest every renderer can shift a cue: this offset plus the largest global delay. The
    /// engine keeps at least 15 s of decoded bitmap history on each side of the playhead whatever it
    /// is told (AE#929), and this is what makes that floor enough, so a wider control has to come
    /// with a wider engine floor.
    static var maximumShift: Double {
        limit + (PlaybackPreferences.subtitleDelayChoices.map(abs).max() ?? 0)
    }

    /// What the engine is told for a session (`maximumSubtitleOffsetSeconds`): only an advance reads
    /// ahead. A later or zero delay is served from the history the engine keeps anyway, and a reach
    /// of 0 stops the forward prefetch that downloads a remote MKV or MP4 twice (AetherEngine#1015).
    static func engineReach(effectiveDelay: Double) -> Double {
        guard effectiveDelay.isFinite else { return 0 }
        return min(maximumShift, max(0, -effectiveDelay))
    }

    /// Steps of a tenth of a second, rounded so repeated steps never drift off the tenth.
    static func stepped(_ value: Double, by steps: Int) -> Double {
        let tenths = (value * 10).rounded() + Double(steps)
        return min(limit, max(-limit, tenths / 10))
    }
}

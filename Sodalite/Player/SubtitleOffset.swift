import Foundation

/// The per-title subtitle offset stepped from the player's subtitle menu. It adds to the global
/// `PlaybackPreferences.subtitleDelaySeconds`, which stays the baseline for every title.
enum SubtitleOffset {
    static let limit: Double = 10

    /// The furthest every renderer can shift a cue: this offset plus the largest global delay. The
    /// engine keeps exactly that much decoded bitmap history around the playhead (AE#929), so a
    /// wider control has to come with a wider value here.
    static var engineReach: Double {
        limit + (PlaybackPreferences.subtitleDelayChoices.map(abs).max() ?? 0)
    }

    /// Steps of a tenth of a second, rounded so repeated steps never drift off the tenth.
    static func stepped(_ value: Double, by steps: Int) -> Double {
        let tenths = (value * 10).rounded() + Double(steps)
        return min(limit, max(-limit, tenths / 10))
    }
}

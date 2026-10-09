import Foundation

/// The per-title subtitle offset stepped from the player's subtitle menu. It adds to the global
/// `PlaybackPreferences.subtitleDelaySeconds`, which stays the baseline for every title.
enum SubtitleOffset {
    static let limit: Double = 10

    /// Steps of a tenth of a second, rounded so repeated steps never drift off the tenth.
    static func stepped(_ value: Double, by steps: Int) -> Double {
        let tenths = (value * 10).rounded() + Double(steps)
        return min(limit, max(-limit, tenths / 10))
    }
}

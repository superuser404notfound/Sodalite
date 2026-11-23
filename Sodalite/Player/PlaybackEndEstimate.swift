import Foundation

/// When the title on screen will finish if it keeps playing from here (Sodalite#251).
nonisolated enum PlaybackEndEstimate {
    /// The rest runs at the playback speed, so 1.5x finishes an hour of film in 40 minutes.
    static func endDate(now: Date, remainingSeconds: Double, rate: Float) -> Date? {
        guard remainingSeconds.isFinite, remainingSeconds > 0, rate.isFinite, rate > 0 else { return nil }
        return now.addingTimeInterval(remainingSeconds / Double(rate))
    }
}

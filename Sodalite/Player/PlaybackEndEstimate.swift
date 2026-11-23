import Foundation

/// When the title on screen will finish if it keeps playing from here (Sodalite#251).
nonisolated enum PlaybackEndEstimate {
    /// The rest runs at the playback speed, so 1.5x finishes an hour of film in 40 minutes.
    static func endDate(now: Date, remainingSeconds: Double, rate: Float) -> Date? {
        guard remainingSeconds.isFinite, remainingSeconds > 0, rate.isFinite, rate > 0 else { return nil }
        return now.addingTimeInterval(remainingSeconds / Double(rate))
    }
}

extension PlayerViewModel {
    /// The end time the transport shows. A scrub moves it with the knob, so it answers "when would I
    /// finish from there". Live has no end of its own, and a pre-roll plays under the movie's item.
    func estimatedEnd(now: Date = Date()) -> Date? {
        guard !isLiveSession, !isPlayingPreroll else { return nil }
        let duration = effectiveDuration
        guard duration > 0 else { return nil }
        if isScrubbing {
            return PlaybackEndEstimate.endDate(now: now, remainingSeconds: duration * Double(1 - scrubProgress),
                                               rate: rate)
        }
        // Paused, the end moves with the clock; playing, it counts from the read (see remainingSampledAt).
        let base = isPlaying ? (remainingSampledAt ?? now) : now
        return PlaybackEndEstimate.endDate(now: base, remainingSeconds: remainingSeconds, rate: rate)
    }

    private var rate: Float {
        Self.speedOptions[max(0, min(Self.speedOptions.count - 1, activeSpeedIndex))]
    }
}

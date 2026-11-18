import Foundation
import AetherEngine

/// Scrubbing for the fullscreen music player, mirroring the video player: pan / skip / held spool all
/// build a preview (`scrubProgress`), committed on Select. Playback keeps running; releasing a spool
/// keeps the preview armed until Select commits (see endContinuousSeek).
extension MusicPlaybackCoordinator {

    /// The 0...1 progress the bar should render: the scrub preview while
    /// scrubbing, otherwise the live playback position.
    var displayProgress: Double {
        guard duration > 0 else { return 0 }
        return isScrubbing
            ? scrubProgress
            : min(max(currentTime / duration, 0), 1)
    }

    /// The seconds the bar should label (preview while scrubbing, else live).
    var displayTime: Double {
        isScrubbing ? scrubProgress * duration : currentTime
    }

    /// Discrete left/right skip: enters the scrub preview and nudges the
    /// position by the configured interval (committed on Select).
    func seekSkip(direction: Int) {
        let dur = duration
        guard dur > 0 else { return }
        beginScrubIfNeeded()
        let delta = Double(direction < 0 ? -1 : 1) * Double(skipSecondsProvider(direction)) / dur
        scrubProgress = min(max(scrubProgress + delta, 0), 1)
    }

    /// Begin a touchpad-pan scrub (records the starting preview position).
    func scrubBegan() {
        beginScrubIfNeeded()
    }

    /// Set the scrub preview to an absolute 0...1 position (the input view
    /// computes it from the pan translation across the bar).
    func scrub(toFraction fraction: Double) {
        guard isScrubbing else { return }
        scrubProgress = min(max(fraction, 0), 1)
    }

    /// Begin a continuous (hold-to-seek) spool in `direction` (-1 left, +1 right), or take over a
    /// running one. Runs on the video player's `SeekScan`, so the distance and the stage come off
    /// the clock and not off a tick count (LTM-R202, the Sodalite#186 error).
    func beginContinuousSeek(direction: Int) {
        let dur = duration
        guard dur > 0 else { return }
        beginScrubIfNeeded()
        if seekScan != nil, continuousSeekTask != nil {
            seekScan?.hold(direction: direction, at: .now)
            return
        }
        seekScan = SeekScan(rates: SeekReadout.scanRates(durationSeconds: dur),
                            direction: direction, heldAt: .now)
        continuousSeekTask?.cancel()
        continuousSeekTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                guard let self, var scan = self.seekScan else { return }
                let dur = self.duration
                guard dur > 0 else { return }
                let now = clock.now
                scan.tick(at: now)
                self.seekScan = scan
                let elapsed = last.duration(to: now) / .seconds(1)
                last = now
                let delta = Double(scan.direction) * Double(scan.rate) * elapsed / dur
                self.scrubProgress = min(max(self.scrubProgress + delta, 0), 1)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// End a continuous spool (press released): stop spooling but KEEP the
    /// scrub preview, exactly like a pan scrub. Playback keeps running; the
    /// user commits the seek with Select.
    func endContinuousSeek() {
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        seekScan = nil
    }

    /// Commit the preview position and seek there. Playback continues as it
    /// was (it was never paused while scrubbing).
    func commitScrub() {
        // Stop a still-running spool first (Select while the long-press is held): its loop only
        // checks Task.isCancelled, so it would keep mutating scrubProgress past the commit and race
        // the next beginScrubIfNeeded's initial position.
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        seekScan = nil
        let dur = duration
        guard isScrubbing, dur > 0 else {
            isScrubbing = false
            return
        }
        let target = scrubProgress * dur
        isScrubbing = false
        seek(to: target)
    }

    func cancelScrub() {
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        seekScan = nil
        isScrubbing = false
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        isScrubbing = true
        scrubProgress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }
}

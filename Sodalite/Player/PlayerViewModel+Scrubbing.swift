import Foundation
import AetherEngine

extension PlayerViewModel {

    var effectiveDuration: Double {
        if player.duration > 0 { return player.duration }
        if let ticks = item.runTimeTicks, ticks > 0 {
            return Double(ticks) / 10_000_000
        }
        return 0
    }

    /// Span `scrubProgress` (0...1) maps across: VOD content duration, or the
    /// buffered DVR window (`liveSeekableRange`) for live. 0 = nothing to scrub
    /// (gates the entry points).
    var scrubReferenceDuration: Double {
        if isLiveSession {
            guard let range = liveSeekableRange,
                  range.upperBound > range.lowerBound else { return 0 }
            return range.upperBound - range.lowerBound
        }
        return effectiveDuration
    }

    /// Min scrubbed seconds that mark a deliberate seek vs the sub-second Siri
    /// Remote touchpad jitter emitted just before a click.
    static let deliberateScrubThresholdSeconds: Double = 5

    /// True when a scrub moved a deliberate distance (not pre-click jitter), so
    /// scrubbing out of an intro commits instead of being hijacked into Skip
    /// Intro. VOD-only; live has no intro segments.
    var scrubMovedMeaningfully: Bool {
        guard isScrubbing else { return false }
        let dur = effectiveDuration
        guard dur > 0 else { return false }
        return abs(Double(scrubProgress - progress)) * dur >= Self.deliberateScrubThresholdSeconds
    }

    func scrub(delta: CGFloat) {
        let dur = scrubReferenceDuration
        guard dur > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            showControls = true
            // Seed the preview so the card has a frame before first movement:
            // VOD prewarms FrameExtractor, live fetches via updateLiveScrubPreview.
            if !isLiveSession {
                scrubPreview.prewarm()
            } else {
                updateLiveScrubPreview()
            }
        }
        // Cancel the timer on EVERY call, not just the first: slow swipes can
        // momentarily flip UIPanGestureRecognizer to .ended (firing
        // scrubPanEnded's 5s auto-hide) while still touching; the old
        // isScrubbing guard let that timer tear the UI down mid-scrub.
        controlsTimer?.cancel()

        scrubProgress = max(0, min(1, scrubStartProgress + Float(delta) * 0.3))
        // scrubTime VOD-only (live bar draws from behindLiveSeconds); preview
        // is still fed for live via updateLiveScrubPreview.
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else { updateLiveScrubPreview() }
    }

    #if os(iOS)
    /// Absolute touch scrub: drag the progress bar to a 0...1 fraction (vs the delta-based touchpad path).
    func scrub(toFraction fraction: Float) {
        let dur = scrubReferenceDuration
        guard dur > 0 else { return }
        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            showControls = true
            if !isLiveSession { scrubPreview.prewarm() } else { updateLiveScrubPreview() }
        }
        controlsTimer?.cancel()
        scrubProgress = max(0, min(1, fraction))
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else {
            updateLiveScrubPreview()
        }
    }
    #endif

    func scrubPanEnded() {
        guard isScrubbing else { return }
        scrubStartProgress = scrubProgress
        // Idle auto-cancel: 5s without Select/Menu discards the scrub and fades
        // controls. scrub(delta:) cancels this the instant panning resumes, so
        // it only fires on real idle.
        controlsTimer?.cancel()
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isScrubbing = false
            scrubPreview.clear()
            hideControls()
        }
    }

    func commitScrub() {
        // Live duration is 0, so the VOD body below would early-return without
        // seeking; commitLiveScrub maps across the moving seekable window.
        if isLiveSession { commitLiveScrub(); return }
        let dur = effectiveDuration
        guard isScrubbing, dur > 0 else {
            isScrubbing = false
            pendingSkipBackOrigin = nil
            skipBackBurstOrigin = nil
            return
        }
        let targetTime = Double(scrubProgress) * dur
        // Set progress BEFORE clearing isScrubbing, else displayedProgress
        // snaps back to the old value until the seek's Combine update lands.
        progress = scrubProgress
        isScrubbing = false
        scrubPreview.clear()
        openSkipBackSubtitlesIfNeeded(targetTime: targetTime)
        Task {
            await player.seek(to: targetTime)
            reportProgressIfNeeded()
            scheduleControlsHide()
        }
    }

    func cancelScrub() {
        isScrubbing = false
        pendingSkipBackOrigin = nil
        skipBackBurstOrigin = nil
        scrubPreview.clear()
        scheduleControlsHide()
    }

    /// Begin a continuous (hold-to-seek) scrub in `direction` (-1 left, +1
    /// right), advancing `scrubProgress` with acceleration until
    /// `endContinuousSeek`. Position is a preview committed only on release.
    func beginContinuousSeek(direction: Int) {
        let dur = scrubReferenceDuration
        guard dur > 0 else { return }
        pendingSkipBackOrigin = nil
        skipBackBurstOrigin = nil

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            scrubProgress = progress
            showControls = true
            if !isLiveSession {
                scrubPreview.prewarm()
            } else {
                updateLiveScrubPreview()
            }
        }
        controlsTimer?.cancel()
        continuousSeekTask?.cancel()

        let dir = Float(direction < 0 ? -1 : 1)
        continuousSeekTask = Task { @MainActor [weak self] in
            let tick = 0.08
            var held = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                // Live re-reads the growing DVR window each tick; VOD is fixed.
                let dur = self.scrubReferenceDuration
                guard dur > 0 else { return }
                // Media-seconds per real second: ramps 15x -> 240x ceiling
                // (~8.6s held) so long films spool quickly.
                let rate = min(15 + held * 26, 240)
                let deltaProgress = dir * Float(rate * tick / dur)
                self.scrubProgress = max(0, min(1, self.scrubProgress + deltaProgress))
                if !self.isLiveSession {
                    self.scrubTime = self.formatSeconds(Double(self.scrubProgress) * dur)
                    self.scrubPreview.update(fraction: self.scrubProgress, durationSeconds: dur)
                } else { self.updateLiveScrubPreview() }
                try? await Task.sleep(for: .seconds(tick))
                held += tick
            }
        }
    }

    /// End a continuous spool (release): the release IS the commit, so a held key lands the same way
    /// the discrete presses next to it do (Sodalite#60, unconditional since #114). The touchpad pan
    /// keeps its own preview-then-confirm ending in `scrubPanEnded`.
    func endContinuousSeek() {
        guard continuousSeekTask != nil else { return }
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        commitScrub()
    }
}

import Foundation
import AetherEngine

/// Sodalite#104: the two seek gestures, as the transport reports them.
///
/// A press of the d-pad is a discrete step of a known length, and its destination is known before it
/// lands; a hold is a scan stepping 15x to 240x that you stop when the picture looks right. Nothing
/// about the second is countable, so a fixed-interval glyph over it would be a lie, and the bar used
/// to draw both as the same knob sliding along the same track.
enum SeekReadout: Equatable {
    /// A burst of presses: the interval each one moves, how many have landed, and which way.
    case press(seconds: Int, count: Int, direction: Int)
    /// A continuous spool, at this multiple of real time.
    case hold(rate: Int, direction: Int)

    var direction: Int {
        switch self {
        case .press(_, _, let direction), .hold(_, let direction): return direction
        }
    }

    /// Sodalite#186: the rates a hold steps through, and how long it has to be held to reach each.
    ///
    /// A rate that climbed every 80 ms read as a counter running for as long as the button was down,
    /// and a burst count printed as "4x" next to it read as a fifth speed. Five stages a viewer can
    /// see change are a speed; a number that never settles is not.
    static let holdStages: [(after: Double, rate: Int)] = [
        (0, 15), (1.5, 30), (3, 60), (5, 120), (7, 240),
    ]

    /// The rate a hold runs at once it has been held `seconds` of real time.
    static func holdRate(heldFor seconds: Double) -> Int {
        holdStages.last(where: { seconds >= $0.after })?.rate ?? holdStages[0].rate
    }

    /// Sodalite#186: what a burst of presses has covered, signed, in place of how many presses it took.
    static func burstTotal(seconds: Int, count: Int, direction: Int) -> String {
        let total = Duration.seconds(seconds * count)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        return (direction < 0 ? "\u{2212}" : "+") + total
    }

    /// Every symbol `SeekReadoutView` can put on screen, so the rail row can ask how tall the
    /// tallest of them is instead of carrying a remembered number (Sodalite#104 round 2).
    ///
    /// The skip glyphs run 8 pt taller than the hold chevrons, which is why only a press ever
    /// overflowed the row.
    static var drawableGlyphNames: [String] {
        var names = ["chevron.left.2", "chevron.right.2"]
        for direction in [-1, 1] {
            names.append(SkipGlyph.name(seconds: 0, direction: direction))
            for seconds in SkipGlyph.numbered.sorted() {
                names.append(SkipGlyph.name(seconds: seconds, direction: direction))
            }
        }
        return names
    }
}

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
            // Sodalite#104: the RAIL's block, not the resident range. A press has to move the knob by
            // the seconds it names, and the knob is drawn across the block.
            guard let range = liveSeekableRange,
                  range.upperBound > range.lowerBound else { return 0 }
            return liveRailBlock.seconds
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

        scrubProgress = clampedScrubProgress(scrubStartProgress + Float(delta) * 0.3)
        // scrubTime VOD-only (live bar draws from behindLiveSeconds); preview
        // is still fed for live via updateLiveScrubPreview.
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else { updateLiveScrubPreview() }
    }

    #if !os(tvOS)
    /// Absolute pointer scrub: drag the progress bar to a 0...1 fraction (vs the delta-based
    /// touchpad path the Siri Remote drives).
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
        scrubProgress = clampedScrubProgress(fraction)
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else {
            updateLiveScrubPreview()
        }
    }
    #endif

    /// Sodalite#104: a live scrub stops at the live edge, which on a programme block is not the right
    /// end of the rail. The part of the block that has not aired is drawn, because a viewer wants to
    /// see how much of the programme is still to come, and it cannot be aimed at.
    var scrubCeiling: Float { isLiveSession ? liveRail.liveEdge : 1 }

    func clampedScrubProgress(_ value: Float) -> Float {
        max(0, min(scrubCeiling, value))
    }

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
            noteScrubDiscarded("no confirming press within 5 s")
            isScrubbing = false
            scrubPreview.clear()
            hideControls()
        }
    }

    /// `thenPlay` resumes once the seek has landed, which is what the Play button means over a
    /// pending scrub: go there and play. The resume is AFTER the seek deliberately, so the engine
    /// anchors the parked clock on the target and resumes from it rather than from the position the
    /// picture still stands on (Sodalite#104 round 2).
    func commitScrub(thenPlay: Bool = false) {
        // Sodalite#104: whichever path ends the scrub, the pending idle and the readout are spent.
        skipCommitTask?.cancel()
        skipCommitTask = nil
        seekReadout = nil
        // Live duration is 0, so the VOD body below would early-return without
        // seeking; commitLiveScrub maps across the moving seekable window.
        if isLiveSession { commitLiveScrub(thenPlay: thenPlay); return }
        let dur = effectiveDuration
        guard isScrubbing, dur > 0 else {
            if isScrubbing { noteScrubDiscarded("the item has no duration to map it across") }
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
            if thenPlay { player.play() }
            reportProgressIfNeeded()
            scheduleControlsHide()
        }
    }

    /// Sodalite#104 round 3: a pending scrub that ends without a seek says why.
    ///
    /// Each of these throws away a gesture the viewer made, and a silent one reads in a device capture
    /// exactly like a confirming press that never arrived. With a line, a capture that shows neither a
    /// seek nor a pause names what took the scrub instead of leaving it to be inferred.
    func noteScrubDiscarded(_ reason: String) {
        LogTap.shared.note("[Scrub] pending scrub discarded without a seek: \(reason)")
    }

    func cancelScrub() {
        skipCommitTask?.cancel()
        skipCommitTask = nil
        seekReadout = nil
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
            // Sodalite#186: both the stage and the distance come off the clock, not off a tick count.
            // A tick that ran late used to move the knob one nominal tick and age the hold by one, so
            // under load the scan crawled below the rate the readout claimed.
            let clock = ContinuousClock()
            let start = clock.now
            var last = start
            while !Task.isCancelled {
                guard let self else { return }
                // Live re-reads the growing DVR window each tick; VOD is fixed.
                let dur = self.scrubReferenceDuration
                guard dur > 0 else { return }
                let now = clock.now
                let rate = SeekReadout.holdRate(heldFor: start.duration(to: now) / .seconds(1))
                let elapsed = last.duration(to: now) / .seconds(1)
                last = now
                let readout = SeekReadout.hold(rate: rate, direction: direction < 0 ? -1 : 1)
                if self.seekReadout != readout { self.seekReadout = readout }
                let deltaProgress = dir * Float(Double(rate) * elapsed / dur)
                self.scrubProgress = max(0, min(1, self.scrubProgress + deltaProgress))
                if !self.isLiveSession {
                    self.scrubTime = self.formatSeconds(Double(self.scrubProgress) * dur)
                    self.scrubPreview.update(fraction: self.scrubProgress, durationSeconds: dur)
                } else { self.updateLiveScrubPreview() }
                try? await Task.sleep(for: .milliseconds(80))
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

import Foundation
import AetherEngine

/// Sodalite#104: the two seek gestures, as the transport reports them.
///
/// A press of the d-pad is a discrete step of a known length, and its destination is known before it
/// lands; a hold is a scan of 8x and up that you stop when the picture looks right. Nothing
/// about the second is countable, so a fixed-interval glyph over it would be a lie, and the bar used
/// to draw both as the same knob sliding along the same track.
enum SeekReadout: Equatable {
    /// A burst of presses: the interval each one moves, how many have landed, and which way.
    case press(seconds: Int, count: Int, direction: Int)
    /// A scan at this multiple of real time, held or latched.
    case hold(rate: Int, direction: Int)

    var direction: Int {
        switch self {
        case .press(_, _, let direction), .hold(_, let direction): return direction
        }
    }

    /// Sodalite#186 round 3: the rates a scan steps through, one stage per press or per 1.5 s held.
    ///
    /// The doubling ladder from 2x spent its first 9 s below 128x and crossed a 24-minute episode in
    /// 19 s with the button down the whole way; the reporter measured Hulu at 13 s for a shorter one.
    /// Three stages reach the top in two presses, and the fourth only joins on a film long enough to
    /// want it.
    static let scanRates = [8, 32, 128, 256]
    static let fullScanLadderMinimumSeconds: Double = 90 * 60
    static let scanStageHoldSeconds: Double = 1.5

    /// The ladder for a title this long. Live passes 0: its rail block is hours at most.
    static func scanRates(durationSeconds: Double) -> [Int] {
        durationSeconds >= fullScanLadderMinimumSeconds ? scanRates : Array(scanRates.dropLast())
    }

    /// How far up the full ladder `rate` stands, 0 to 1. By stage rather than by rate: on a ladder
    /// that multiplies, a linear share leaves every stage below the top near zero.
    static func holdStageFraction(_ rate: Int) -> Double {
        guard let index = scanRates.lastIndex(where: { $0 <= rate }) else { return 0 }
        return Double(index) / Double(max(1, scanRates.count - 1))
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

/// Sodalite#186 round 3: a scan the way the system player and Hulu run one.
///
/// Holding a direction starts it and climbs a stage every 1.5 s. Letting go no longer commits: the
/// scan keeps running at the stage it reached, so a long seek does not have to be held all the way.
/// A press the same way steps up, a press the other way steps down and, from the bottom stage, turns
/// the scan around. Select or Play lands it, Menu throws it away.
struct SeekScan: Equatable {
    let rates: [Int]
    private(set) var stage = 0
    private(set) var direction: Int
    private var holdBegan: ContinuousClock.Instant?
    private var holdStartStage = 0

    init(rates: [Int], direction: Int, heldAt: ContinuousClock.Instant) {
        self.rates = rates
        self.direction = direction < 0 ? -1 : 1
        holdBegan = heldAt
    }

    var rate: Int { rates[stage] }
    var isHeld: Bool { holdBegan != nil }

    /// A hold while the scan runs: the same way climbs on from where it stands, the other way turns
    /// it around from the bottom stage.
    mutating func hold(direction: Int, at now: ContinuousClock.Instant) {
        let direction = direction < 0 ? -1 : 1
        if direction != self.direction {
            self.direction = direction
            stage = 0
        }
        holdBegan = now
        holdStartStage = stage
    }

    mutating func release(at now: ContinuousClock.Instant) {
        tick(at: now)
        holdBegan = nil
    }

    mutating func press(direction: Int, at now: ContinuousClock.Instant) {
        tick(at: now)
        if (direction < 0 ? -1 : 1) == self.direction {
            stage = min(stage + 1, rates.count - 1)
        } else if stage > 0 {
            stage -= 1
        } else {
            self.direction = -self.direction
        }
        if holdBegan != nil {
            holdBegan = now
            holdStartStage = stage
        }
    }

    mutating func tick(at now: ContinuousClock.Instant) {
        guard let holdBegan else { return }
        let climbed = Int(holdBegan.duration(to: now) / .seconds(SeekReadout.scanStageHoldSeconds))
        stage = min(rates.count - 1, holdStartStage + climbed)
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

        // A swipe takes over a running scan from where it stands.
        if continuousSeekTask != nil {
            stopContinuousSeek()
            seekReadout = nil
            scrubStartProgress = scrubProgress
        }
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
        stopContinuousSeek()
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
        stopContinuousSeek()
        skipCommitTask?.cancel()
        skipCommitTask = nil
        seekReadout = nil
        isScrubbing = false
        pendingSkipBackOrigin = nil
        skipBackBurstOrigin = nil
        scrubPreview.clear()
        scheduleControlsHide()
    }

    /// A held direction (-1 left, +1 right) starts a scan, or takes over a running one (`SeekScan`).
    /// Position is a preview until Select, Play or, from a keyboard, the release lands it.
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

        if seekScan != nil, continuousSeekTask != nil {
            seekScan?.hold(direction: direction, at: .now)
            return
        }
        seekScan = SeekScan(rates: SeekReadout.scanRates(durationSeconds: isLiveSession ? 0 : dur),
                            direction: direction, heldAt: .now)
        continuousSeekTask?.cancel()
        continuousSeekTask = Task { @MainActor [weak self] in
            // Sodalite#186: both the stage and the distance come off the clock, not off a tick count.
            // A tick that ran late used to move the knob one nominal tick and age the hold by one, so
            // under load the scan crawled below the rate the readout claimed.
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                guard let self, var scan = self.seekScan else { return }
                // Live re-reads the growing DVR window each tick; VOD is fixed.
                let dur = self.scrubReferenceDuration
                guard dur > 0 else { return }
                let now = clock.now
                scan.tick(at: now)
                self.seekScan = scan
                let elapsed = last.duration(to: now) / .seconds(1)
                last = now
                let readout = SeekReadout.hold(rate: scan.rate, direction: scan.direction)
                if self.seekReadout != readout { self.seekReadout = readout }
                let deltaProgress = Float(scan.direction) * Float(Double(scan.rate) * elapsed / dur)
                self.scrubProgress = max(0, min(1, self.scrubProgress + deltaProgress))
                if !self.isLiveSession {
                    self.scrubTime = self.formatSeconds(Double(self.scrubProgress) * dur)
                    self.scrubPreview.update(fraction: self.scrubProgress, durationSeconds: dur)
                } else { self.updateLiveScrubPreview() }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// True while a scan runs with no direction held, so the remote's presses steer it instead of
    /// skipping.
    var isScanLatched: Bool {
        continuousSeekTask != nil && seekScan?.isHeld == false
    }

    /// Sodalite#186 round 3: the remote lets go of a scan without landing it.
    func latchContinuousSeek() {
        guard continuousSeekTask != nil else { return }
        seekScan?.release(at: .now)
    }

    func stepLatchedScan(direction: Int) {
        guard isScanLatched, var scan = seekScan else { return }
        scan.press(direction: direction, at: .now)
        seekScan = scan
        seekReadout = .hold(rate: scan.rate, direction: scan.direction)
    }

    func stopContinuousSeek() {
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        seekScan = nil
    }

    /// The keyboard's release, which has no Select to wait for: the release IS the commit (Sodalite#60,
    /// unconditional since #114). The touchpad pan keeps its own preview-then-confirm ending in
    /// `scrubPanEnded`.
    func endContinuousSeek() {
        guard continuousSeekTask != nil else { return }
        stopContinuousSeek()
        commitScrub()
    }
}

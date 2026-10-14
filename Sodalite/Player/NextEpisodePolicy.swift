import Foundation

/// Pure decision logic for the next-episode flow: when the end-window opens, and where end-of-media
/// routes. Kept engine- and UIKit-free so the state machine is unit-testable without a running session,
/// mirroring PlayerLockProgress. Both call sites live in PlayerViewModel's Combine sinks.
enum NextEpisodePolicy {

    /// How far from the end the overlay opens when the server has no outro marker.
    static let fallbackWindowSeconds: Double = 30

    /// Where the countdown sits (Sodalite#133). At the credits it runs over them, so the switch cuts
    /// whatever is left; at the end of the source it is only a warning and the episode plays out.
    /// Without an outro marker there are no credits to anchor to, so that path is always `.end`.
    enum CountdownAnchor: String, CaseIterable, Sendable, Identifiable {
        case outro
        case end

        var id: String { rawValue }
    }

    /// The anchor actually in force. Without an outro marker there are no credits to place the countdown
    /// on, and honouring the credits preference there would arm it at the 30s fallback window, cutting
    /// that much out of the episode itself.
    static func effectiveAnchor(preferred: CountdownAnchor, hasOutroMarker: Bool) -> CountdownAnchor {
        hasOutroMarker ? preferred : .end
    }

    /// What the countdown starts from, or nil while it must stay unarmed and the card sits ringless.
    ///
    /// Neither anchor lets the countdown outlive the source: `.end` waits until the remaining seconds
    /// fit inside it and is then seeded with them, `.outro` arms at once but is capped at what is left.
    /// The cap matters on short credits, where the old fixed length ran on past `.ended` and parked a
    /// frozen last frame until it fired.
    ///
    /// `lengthSeconds == 0` is the countdown switched off, not a zero-second one: an instant jump at
    /// the marker is what `autoSkipOutro` does, and two settings must not express the same wish.
    static func countdownStart(
        anchor: CountdownAnchor,
        lengthSeconds: Int,
        remainingSeconds: Double
    ) -> Int? {
        guard lengthSeconds > 0, remainingSeconds > 0 else { return nil }
        let left = max(1, Int(ceil(remainingSeconds)))
        switch anchor {
        case .outro: return min(lengthSeconds, left)
        case .end: return remainingSeconds <= Double(lengthSeconds) ? left : nil
        }
    }

    /// True while the playhead sits in the window that shows the overlay and arms the countdown.
    ///
    /// Single definition on purpose: the clock sink's overlay trigger and the two cancel-latch resets
    /// must agree on the window, else a cancel taken inside it can never be released.
    /// `sourceTime` is the absolute source-timeline value (outro markers are source-relative), while
    /// `remainingSeconds` is measured on the presentation clock.
    static func isInsideTriggerWindow(
        outroStartSeconds: Double?,
        sourceTime: Double,
        remainingSeconds: Double
    ) -> Bool {
        // With a marker, the credits define the window; the fallback deliberately does not apply, a
        // short outro would otherwise open the overlay ahead of the credits it was measured for.
        if let outroStartSeconds { return sourceTime >= outroStartSeconds }
        return remainingSeconds < fallbackWindowSeconds
    }

    /// How far ahead of the switch the successor is warmed (AetherEngine#551).
    ///
    /// Deliberately NOT the overlay's window. Two minutes rather than thirty seconds, because the
    /// warm has to finish before the switch rather than start before it, and because the overlay's
    /// window can BE the switch: with an outro marker the window opens at the credits, and a viewer
    /// who has outro auto-skip on leaves at that same instant, so a warm armed there would still be
    /// on the wire when the next episode loads.
    ///
    /// It is also the reason the warm is not armed at the start of the episode instead, where the
    /// successor has been known since the first frame: the PlaybackInfo it rests on would be forty
    /// minutes old by the time it is used, and the bytes would sit in memory for all of it.
    static let successorWarmLeadSeconds: Double = 120

    /// True once the successor is close enough to be worth warming.
    ///
    /// Same two inputs as the trigger window and the same split between them: with a marker the
    /// credits are the anchor, and the lead is measured back from there; without one it is measured
    /// from the end. The fallback window is narrower than this lead, so on a source with no marker
    /// the warm is always armed before the overlay opens, never after.
    static func shouldWarmSuccessor(
        outroStartSeconds: Double?,
        sourceTime: Double,
        remainingSeconds: Double
    ) -> Bool {
        if let outroStartSeconds {
            return sourceTime >= outroStartSeconds - successorWarmLeadSeconds
        }
        return remainingSeconds < successorWarmLeadSeconds
    }

    /// What the session does when the engine reports end-of-media.
    enum EndOfPlaybackOutcome: Equatable {
        /// Someone else owns the transition (countdown already running, overlay already parked), or
        /// playback never produced a frame.
        case ignore
        /// Close the PiP window and end the session rather than parking a black frame in the corner.
        case endPictureInPicture
        /// Show the overlay and start the auto-advance countdown.
        case showOverlayAndAdvance
        /// Switch to the successor right away, without putting the card back on screen: the user
        /// dismissed it, or runs with the countdown switched off (Sodalite#67). Both asked for the
        /// episode to play out and the next one to follow, so a card at the seam is only a flash.
        case advanceWithoutOverlay
        /// Nothing follows: close the player, same as a movie reaching its end.
        case dismissPlayer
    }

    /// Routes end-of-media. Exhaustive by construction: the earlier inline chain had a hole for a
    /// cancelled advance (next episode known, user rejected it), which matched no branch and left the
    /// player open on a terminal `.ended` engine session where seek and play are both no-ops.
    ///
    /// `advanceCancelled` is a rejection taken ON the terminal state (the card was parked at the end);
    /// `overlayDismissed` is the card being closed while the source still runs, which is a different
    /// wish and must not cost the advance (Sodalite#67). `cardEnabled` off routes like a card that
    /// was dismissed on every pass.
    static func endOfPlaybackOutcome(
        hasStartedPlaying: Bool,
        pictureInPictureActive: Bool,
        pictureInPictureCanAdvance: Bool,
        hasNextEpisode: Bool,
        advanceCancelled: Bool,
        overlayDismissed: Bool,
        cardEnabled: Bool,
        autoplayEnabled: Bool,
        countdownEnabled: Bool,
        countdownRunning: Bool,
        overlayVisible: Bool
    ) -> EndOfPlaybackOutcome {
        guard hasStartedPlaying else { return .ignore }
        let overlayDismissed = overlayDismissed || !cardEnabled

        // Dismissing the card means two different things by setting: with autoplay ON it only clears
        // the screen for the credits, with autoplay OFF the card was the entire offer, so closing it
        // rejects the successor.
        let rejected = advanceCancelled || (overlayDismissed && !autoplayEnabled)
        // A rejected advance is "no successor for this session", so it routes like end-of-content.
        let willAdvance = hasNextEpisode && !rejected

        if pictureInPictureActive {
            // In-place item handover keeps the window alive (native backend); every other case ends it.
            guard willAdvance, pictureInPictureCanAdvance else { return .endPictureInPicture }
        }
        if willAdvance {
            if countdownRunning { return .ignore }
            if autoplayEnabled, overlayDismissed || !countdownEnabled { return .advanceWithoutOverlay }
            return .showOverlayAndAdvance
        }
        // A visible overlay (queue exhausted, manual pick still offered) keeps the player up.
        return overlayVisible ? .ignore : .dismissPlayer
    }
}

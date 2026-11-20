import Testing
@testable import Sodalite

struct NextEpisodePolicyTests {

    // MARK: - Trigger window

    @Test func noOutroMarkerOpensThirtySecondsFromTheEnd() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 100, remainingSeconds: 45) == false)
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 100, remainingSeconds: 25) == true)
    }

    @Test func noOutroMarkerWindowIsStrictlyUnderThirty() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 100, remainingSeconds: 30) == false)
    }

    @Test func outroMarkerOpensAtItsStart() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 1199, remainingSeconds: 200) == false)
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 1200, remainingSeconds: 200) == true)
    }

    /// With a marker present the 30s fallback must not fire: a short outro would otherwise open the
    /// overlay before the credits it was meant to sit on.
    @Test func outroMarkerSupersedesTheRemainingFallback() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 1100, remainingSeconds: 10) == false)
    }

    /// The cancel latch is scoped to one pass through the window: scrubbing back out of it clears the
    /// cancel, so playing forward again re-triggers overlay + auto-advance.
    @Test func scrubbingOutOfTheWindowLeavesTheCancelScope() {
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: nil, sourceTime: 600, remainingSeconds: 900) == false)
        #expect(NextEpisodePolicy.isInsideTriggerWindow(
            outroStartSeconds: 1200, sourceTime: 600, remainingSeconds: 900) == false)
    }

    // MARK: - End-of-playback routing

    private func outcome(
        hasStartedPlaying: Bool = true,
        pictureInPictureActive: Bool = false,
        pictureInPictureCanAdvance: Bool = true,
        hasNextEpisode: Bool = true,
        advanceCancelled: Bool = false,
        overlayDismissed: Bool = false,
        cardEnabled: Bool = true,
        autoplayEnabled: Bool = true,
        countdownEnabled: Bool = true,
        countdownRunning: Bool = false,
        overlayVisible: Bool = false
    ) -> NextEpisodePolicy.EndOfPlaybackOutcome {
        NextEpisodePolicy.endOfPlaybackOutcome(
            hasStartedPlaying: hasStartedPlaying,
            pictureInPictureActive: pictureInPictureActive,
            pictureInPictureCanAdvance: pictureInPictureCanAdvance,
            hasNextEpisode: hasNextEpisode,
            advanceCancelled: advanceCancelled,
            overlayDismissed: overlayDismissed,
            cardEnabled: cardEnabled,
            autoplayEnabled: autoplayEnabled,
            countdownEnabled: countdownEnabled,
            countdownRunning: countdownRunning,
            overlayVisible: overlayVisible
        )
    }

    @Test func endBeforeFirstFrameIsIgnored() {
        #expect(outcome(hasStartedPlaying: false) == .ignore)
    }

    @Test func movieEndDismissesThePlayer() {
        #expect(outcome(hasNextEpisode: false) == .dismissPlayer)
    }

    @Test func episodeEndStartsTheAdvance() {
        #expect(outcome() == .showOverlayAndAdvance)
    }

    @Test func runningCountdownOwnsTheAdvance() {
        #expect(outcome(countdownRunning: true) == .ignore)
    }

    /// Regression: a cancelled advance used to match no branch at all, leaving the player open on a
    /// terminal engine session (seek and play are no-ops in `.ended`), i.e. a dead screen. A rejected
    /// next episode means "no successor for this session", so it routes like a movie's end.
    @Test func cancelledAdvanceDismissesThePlayer() {
        #expect(outcome(advanceCancelled: true) == .dismissPlayer)
    }

    @Test func cancelledAdvanceDismissesEvenWithACountdownStillRegistered() {
        #expect(outcome(advanceCancelled: true, countdownRunning: true) == .dismissPlayer)
    }

    /// The queue-exhausted overlay is already on screen; end-of-media must not dismiss out from under it.
    @Test func visibleOverlayWithoutASuccessorHoldsThePlayer() {
        #expect(outcome(hasNextEpisode: false, overlayVisible: true) == .ignore)
    }

    @Test func pipAdvancesInPlaceWhenTheBackendCan() {
        #expect(outcome(pictureInPictureActive: true) == .showOverlayAndAdvance)
    }

    @Test func pipClosesWhenTheBackendCannotAdvance() {
        #expect(outcome(pictureInPictureActive: true, pictureInPictureCanAdvance: false)
                == .endPictureInPicture)
    }

    @Test func pipClosesOnACancelledAdvance() {
        #expect(outcome(pictureInPictureActive: true, advanceCancelled: true) == .endPictureInPicture)
    }

    @Test func pipClosesAtRealEndOfContent() {
        #expect(outcome(pictureInPictureActive: true, hasNextEpisode: false) == .endPictureInPicture)
    }

    // MARK: - Dismissed card (Sodalite#67)

    /// Closing the card mid-episode only takes it off the screen: the credits play out and the switch
    /// still happens at the end. It used to route like a rejected successor, so the player closed and
    /// left the user on the finished episode's detail page.
    @Test func dismissedCardStillAdvancesAtTheEnd() {
        #expect(outcome(overlayDismissed: true) == .advanceWithoutOverlay)
    }

    /// With autoplay off the card IS the whole offer, so dismissing it rejects the successor and the
    /// session ends like a movie's.
    @Test func dismissedCardWithAutoplayOffEndsTheSession() {
        #expect(outcome(overlayDismissed: true, autoplayEnabled: false) == .dismissPlayer)
    }

    @Test func dismissedCardWithoutASuccessorStillEndsTheSession() {
        #expect(outcome(hasNextEpisode: false, overlayDismissed: true) == .dismissPlayer)
    }

    /// A cancel taken ON the terminal `.ended` state stays a rejection, whatever the settings say.
    @Test func terminalCancelOutranksTheDismissedCard() {
        #expect(outcome(advanceCancelled: true, overlayDismissed: true) == .dismissPlayer)
    }

    // MARK: - Card switched off

    /// Autoplay on, card off: the episode plays out and the successor follows at the real end,
    /// with no card at the seam.
    @Test func cardOffAdvancesAtTheEnd() {
        #expect(outcome(cardEnabled: false) == .advanceWithoutOverlay)
    }

    /// Autoplay off, card off: nothing is offered, so the player closes like at a movie's end and the
    /// viewer lands back on the series page.
    @Test func cardOffWithAutoplayOffEndsTheSession() {
        #expect(outcome(cardEnabled: false, autoplayEnabled: false) == .dismissPlayer)
    }

    @Test func cardOffWithoutASuccessorEndsTheSession() {
        #expect(outcome(hasNextEpisode: false, cardEnabled: false) == .dismissPlayer)
    }

    @Test func cardOffInPiPAdvancesInPlace() {
        #expect(outcome(pictureInPictureActive: true, cardEnabled: false) == .advanceWithoutOverlay)
    }

    @Test func cardOffWithAutoplayOffClosesPiP() {
        #expect(outcome(pictureInPictureActive: true, cardEnabled: false, autoplayEnabled: false)
                == .endPictureInPicture)
    }

    // MARK: - Countdown switched off (Sodalite#67)

    /// Countdown off: the card sits there without a timer while the credits run, and the switch fires
    /// at the real end without flashing the card again.
    @Test func countdownOffAdvancesWithoutTheCardAtTheEnd() {
        #expect(outcome(countdownEnabled: false) == .advanceWithoutOverlay)
    }

    /// Autoplay off outranks the countdown switch: nothing advances, the card parks for a manual pick.
    @Test func countdownOffWithAutoplayOffParksTheCard() {
        #expect(outcome(autoplayEnabled: false, countdownEnabled: false) == .showOverlayAndAdvance)
    }

    @Test func countdownOffInPiPAdvancesInPlace() {
        #expect(outcome(pictureInPictureActive: true, countdownEnabled: false) == .advanceWithoutOverlay)
    }

    @Test func countdownOffWithoutASuccessorEndsTheSession() {
        #expect(outcome(hasNextEpisode: false, countdownEnabled: false) == .dismissPlayer)
    }

    /// The default path is untouched: card plus countdown at the seam.
    @Test func defaultsStillShowTheCardAndCountDown() {
        #expect(outcome() == .showOverlayAndAdvance)
    }

    // MARK: - Countdown arming (Sodalite#133)

    private func start(
        anchor: NextEpisodePolicy.CountdownAnchor = .outro,
        lengthSeconds: Int = 15,
        remainingSeconds: Double
    ) -> Int? {
        NextEpisodePolicy.countdownStart(
            anchor: anchor, lengthSeconds: lengthSeconds, remainingSeconds: remainingSeconds)
    }

    /// The whole point of the end anchor: minutes of credits pass with the card up and no ring, so the
    /// switch cannot land before the last frame.
    @Test func endAnchorStaysUnarmedThroughLongCredits() {
        #expect(start(anchor: .end, remainingSeconds: 120) == nil)
        #expect(start(anchor: .end, remainingSeconds: 15.5) == nil)
    }

    @Test func endAnchorArmsWithTheSecondsActuallyLeft() {
        #expect(start(anchor: .end, remainingSeconds: 15) == 15)
        #expect(start(anchor: .end, remainingSeconds: 4) == 4)
    }

    /// Rounding down would fire the switch a second early, which is the clipping this fixes, one second
    /// at a time.
    @Test func theSeedRoundsUp() {
        #expect(start(anchor: .end, remainingSeconds: 12.1) == 13)
        #expect(start(anchor: .end, remainingSeconds: 0.4) == 1)
    }

    /// The outro anchor is the old behaviour and keeps it: the ring starts at the marker and the credits
    /// are cut wherever it runs out.
    @Test func outroAnchorArmsAtOnce() {
        #expect(start(anchor: .outro, remainingSeconds: 120) == 15)
    }

    /// Short credits: a countdown longer than what is left would park a frozen last frame until it fires,
    /// so it is capped and the two anchors converge.
    @Test func outroAnchorNeverOutlivesTheSource() {
        #expect(start(anchor: .outro, remainingSeconds: 8) == 8)
        #expect(start(anchor: .outro, remainingSeconds: 7.2) == 8)
    }

    /// Off is the absence of a countdown, never a zero-second one: a zero-second countdown at the outro
    /// anchor would be an instant jump, which is what `autoSkipOutro` already does.
    @Test func lengthZeroNeverArms() {
        #expect(start(anchor: .outro, lengthSeconds: 0, remainingSeconds: 120) == nil)
        #expect(start(anchor: .end, lengthSeconds: 0, remainingSeconds: 3) == nil)
    }

    /// No marker means no credits to anchor to. Honouring the credits preference there would arm at the
    /// 30s fallback window and cut the last quarter minute out of the episode itself.
    @Test func withoutAMarkerTheAnchorIsAlwaysTheEnd() {
        #expect(NextEpisodePolicy.effectiveAnchor(preferred: .outro, hasOutroMarker: false) == .end)
        #expect(NextEpisodePolicy.effectiveAnchor(preferred: .end, hasOutroMarker: false) == .end)
    }

    @Test func withAMarkerThePreferenceDecides() {
        #expect(NextEpisodePolicy.effectiveAnchor(preferred: .outro, hasOutroMarker: true) == .outro)
        #expect(NextEpisodePolicy.effectiveAnchor(preferred: .end, hasOutroMarker: true) == .end)
    }

    @Test func nothingArmsAtOrPastTheEnd() {
        #expect(start(anchor: .outro, remainingSeconds: 0) == nil)
        #expect(start(anchor: .end, remainingSeconds: -2) == nil)
    }
}

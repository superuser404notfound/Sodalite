import Testing
@testable import Sodalite

@Suite("Transport auto-hide and paused visibility (Sodalite#93, #110)")
struct TransportAutoHideTests {
    @Test("A fired auto-hide keeps a paused transport on screen")
    func pausedTransportSurvivesTheTimer() {
        #expect(TransportAutoHide.hides(isPlaying: false) == false)
        #expect(TransportAutoHide.hides(isPlaying: true) == true)
    }

    @Test("An ordinary pause raises the transport")
    func ordinaryPauseRaisesTransport() {
        #expect(TransportAutoHide.raisesTransport(errorVisible: false, inputLocked: false))
    }

    @Test("An error screen keeps the transport down so Menu still dismisses the player")
    func errorScreenKeepsTransportDown() {
        #expect(!TransportAutoHide.raisesTransport(errorVisible: true, inputLocked: false))
    }

    // MARK: - Music Now Playing chrome auto-hide (Sodalite#110)

    @Test("The music chrome runs on the same two constants, not a second set")
    func musicChromeSharesTheTransportRule() {
        // Sodalite#110 briefly gave the music screen a rule of its own, refusing to fire while a queue
        // row held focus. That is where focus sits after any look at the queue, so the auto-hide never
        // fired again; the view keeps a focusable sink alive instead. Nothing is left to diverge.
        #expect(TransportAutoHide.idleDelay == .seconds(5))
        #expect(TransportAutoHide.hides(isPlaying: true))
        #expect(!TransportAutoHide.hides(isPlaying: false))
    }

    @Test("The child lock keeps the transport down")
    func childLockKeepsTransportDown() {
        #expect(!TransportAutoHide.raisesTransport(errorVisible: false, inputLocked: true))
        #expect(!TransportAutoHide.raisesTransport(errorVisible: true, inputLocked: true))
    }

    // MARK: - Resume press (Sodalite#168)

    @Test("A press that resumed hides the transport sooner than the idle countdown")
    func resumePressUsesTheShortDelay() {
        #expect(TransportAutoHide.delay(afterResumePress: true) == TransportAutoHide.resumeDelay)
        #expect(TransportAutoHide.resumeDelay < TransportAutoHide.idleDelay)
    }

    @Test("Every other return to playing keeps the idle countdown")
    func otherPlayingTransitionsKeepTheIdleDelay() {
        #expect(TransportAutoHide.delay(afterResumePress: false) == TransportAutoHide.idleDelay)
    }
}

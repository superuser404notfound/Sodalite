/// The two rules that decide whether the transport is on screen while playback is not running
/// (Sodalite#93). Both used to live inline in `PlayerViewModel` and both were wrong there.
///
/// `hides` is the auto-hide's liveness check, and its whole point is WHERE it is evaluated. The old
/// code checked `isPlaying` when it ARMED the 5s timer, inside `togglePlayPause`, one statement after
/// `player.togglePlayPause()`. That call is asynchronous and the engine's state sink is delivered on a
/// later runloop turn (`.receive(on:)`), so on the very press that paused, `isPlaying` still carried
/// `true`, the guard passed, and five seconds later a paused still frame lost its transport. Asking at
/// FIRE time is the fix; nothing about the answer itself is interesting.
///
/// `raisesTransport` covers the other half: a pause from outside the app (Siri, Control Center, or the
/// AVKit transport that co-owns the hardware play/pause button on the native path) reaches the host only
/// as an engine state change, and that path never touched control visibility at all. It raises the
/// transport now, except in the two states that would misread the flag: behind an error screen the
/// session is over and Menu has to stay "dismiss the player" rather than "close the transport", and the
/// iOS child lock deliberately cleared it. The loading spinner is NOT among them, because it and this
/// decision arrive from different publishers in no fixed order, and a raise skipped on a stale `true`
/// would never be retried.
enum TransportAutoHide {
    /// The idle countdown both auto-hides run on. Five seconds because three hides mid-read on a long
    /// title and ten reads as broken rather than deliberate.
    static let idleDelay: Duration = .seconds(5)

    /// Sodalite#168: a press that resumes playback says the user is done with the transport, so it
    /// leaves after a beat instead of the full idle. Long enough to watch the play icon flip, which is
    /// the press's only confirmation.
    static let resumeDelay: Duration = .milliseconds(1500)

    /// Which countdown a `.playing` transition arms. Decided from the press's intent, recorded before
    /// the engine is asked, because `isPlaying` on that press still carries the old state (#93).
    static func delay(afterResumePress: Bool) -> Duration {
        afterResumePress ? resumeDelay : idleDelay
    }

    /// Also the music Now Playing chrome's rule (Sodalite#110), asked at its fire time for the same
    /// reason. That screen carries no extra clause of its own. It briefly had one, refusing to fire
    /// while a queue row held focus, on the theory that hiding the focused view strands the user; in
    /// practice that is where focus sits after any look at the queue, so the auto-hide simply never
    /// fired again, which is how it was reported. The stranding is a job for the view, which keeps one
    /// focusable sink alive behind the hidden chrome, not for a clause that trades one bug for another.
    static func hides(isPlaying: Bool) -> Bool { isPlaying }

    static func raisesTransport(errorVisible: Bool, inputLocked: Bool) -> Bool {
        !errorVisible && !inputLocked
    }
}
